# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeSet, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:entity) { MemoryEntity.new(id: 101, name: "SynthWidget", entity_type: "Component") }
  let(:observation) { MemoryObservation.new(id: 202, memory_entity_id: 101, content: "synthetic") }
  let(:relation) { MemoryRelation.new(id: 303, from_entity_id: 101, to_entity_id: 102, relation_type: "depends_on") }

  def open_context(kind: "graph.write", **options)
    described_class.record(kind: kind, **options) { |context| context }
  end

  describe "kinds" do
    it "accepts every listed kind and the policy/explore patterns" do
      (described_class::KINDS + %w[policy.dangling explore.move_node]).each do |kind|
        expect(described_class.valid_kind?(kind)).to be(true), kind
      end
    end

    it "refuses unknown kinds when recording" do
      expect(described_class.valid_kind?("policy.Bad-Name")).to be(false)
      expect { described_class.record(kind: "graph.frobnicate") { nil } }.to raise_error(ArgumentError, /unknown/)
    end
  end

  describe ".record" do
    it "sets Current.change_set only inside the block and returns the block's value" do
      value = described_class.record(kind: "graph.edit") do |context|
        expect(Current.change_set).to be(context)
        :done
      end

      expect(value).to eq(:done)
      expect(Current.change_set).to be_nil
    end

    it "joins an open set instead of opening a second one" do
      described_class.record(kind: "graph.delete", actor: "mcp:graph_delete") do |outer|
        described_class.record(kind: "merge", actor: "someone else") do |inner|
          expect(inner).to be(outer)
          expect(inner.kind).to eq("graph.delete")
        end
      end
    end

    it "writes no row while nothing changes" do
      expect { described_class.record(kind: "graph.write") { nil } }.not_to change(described_class, :count)
    end

    it "writes one row for many changes" do
      context = open_context(actor: "operator:steve@127.0.0.1", summary: "two steps")
      context.add_merge_step!({ "source" => { "id" => 1 } })
      context.add_merge_step!({ "source" => { "id" => 2 } })

      set = described_class.find_by!(uuid: context.uuid)
      expect(described_class.count).to eq(1)
      expect(set).to have_attributes(kind: "graph.write", actor: "operator:steve@127.0.0.1", summary: "two steps")
      expect(set.section(:merges).map { |step| step.dig("source", "id") }).to eq([ 1, 2 ])
      expect(set.snapshot["v"]).to eq(described_class::SNAPSHOT_VERSION)
      expect(set.snapshot_bytes).to eq(set.snapshot.to_json.bytesize)
    end

    it "forgets a row whose first write rolled back and inserts it again on the next write" do
      context = open_context
      ActiveRecord::Base.transaction do
        context.add_merge_step!({ "attempt" => 1 })
        expect(described_class.count).to eq(1)
        raise ActiveRecord::Rollback
      end

      expect(described_class.count).to eq(0)
      expect(context.id).to be_nil

      context.add_merge_step!({ "attempt" => 2 })
      expect(described_class.find(context.id).section(:merges)).to eq([ { "attempt" => 2 } ])
    end

    it "drops entries added in a rolled-back transaction but keeps committed ones" do
      context = open_context
      context.add_merge_step!({ "attempt" => 1 })
      ActiveRecord::Base.transaction do
        context.add_merge_step!({ "attempt" => 2 })
        raise ActiveRecord::Rollback
      end
      context.add_merge_step!({ "attempt" => 3 })

      expect(described_class.find(context.id).section(:merges)).to eq([ { "attempt" => 1 }, { "attempt" => 3 } ])
    end

    it "restores the outer state when a released savepoint's transaction rolls back" do
      context = open_context
      ActiveRecord::Base.transaction do
        context.add_merge_step!({ "attempt" => 1 })
        ActiveRecord::Base.transaction(requires_new: true) { context.add_merge_step!({ "attempt" => 2 }) }
        raise ActiveRecord::Rollback
      end

      expect(context.id).to be_nil
      expect(context.snapshot).not_to have_key("merges")
    end
  end

  describe "strategy" do
    it "starts as an audit set with the 30-day window and takes the first written entity as subject" do
      context = open_context
      freeze_time do
        context.note_audit!(observation, "create")
        set = described_class.find(context.id)

        expect(set).to have_attributes(undo_strategy: "audit", not_undoable_reason: nil,
                                       subject_type: "MemoryEntity", subject_id: 101,
                                       undoable_until: 30.days.from_now)
      end
    end

    it "becomes a merge set with the 7-day window on the first merge step" do
      context = open_context(kind: "merge")
      freeze_time do
        context.within_merge_step { context.note_audit!(entity, "delete") }
        expect(described_class.find(context.id)).to have_attributes(undo_strategy: "merge", undoable_until: 7.days.from_now)
      end
    end

    it "is mixed when a merge follows another write" do
      context = open_context
      context.note_audit!(relation, "create")
      context.within_merge_step { nil }

      expect(described_class.find(context.id)).to have_attributes(undo_strategy: "none", not_undoable_reason: "mixed_merge", undoable_until: nil)
    end

    it "is mixed when another write follows a merge" do
      context = open_context
      context.within_merge_step { context.note_audit!(entity, "update") }
      context.note_audit!(relation, "update")

      expect(described_class.find(context.id).not_undoable_reason).to eq("mixed_merge")
    end

    it "is not undoable after a hard delete of an entity or observation outside a merge" do
      [ entity, observation ].each do |record|
        context = open_context(kind: "graph.delete")
        context.note_audit!(record, "delete")
        expect(described_class.find(context.id).not_undoable_reason).to eq("hard_delete")
      end
    end

    it "keeps relation deletes undoable" do
      context = open_context(kind: "graph.delete")
      context.note_audit!(relation, "delete")

      expect(described_class.find(context.id).undo_strategy).to eq("audit")
    end

    it "marks an audit failure as audit_incomplete and counts it" do
      context = open_context
      context.note_audit!(relation, "update")
      context.note_audit_failure!

      set = described_class.find(context.id)
      expect(set).to have_attributes(undo_strategy: "none", not_undoable_reason: "audit_incomplete")
      expect(set.snapshot["audit_failures"]).to eq(1)
    end

    it "keeps the first reason" do
      context = open_context
      context.note_audit!(entity, "delete")
      context.note_audit_failure!

      expect(described_class.find(context.id).not_undoable_reason).to eq("hard_delete")
    end

    it "drops the large sections over the size cap, keeps their sizes and is not undoable" do
      stub_const("ChangeSet::MAX_SNAPSHOT_BYTES", 200)
      context = open_context(kind: "merge")
      context.within_merge_step { context.add_merge_step!({ "source" => { "description" => "x" * 300 } }) }

      set = described_class.find(context.id)
      expect(set).to have_attributes(undo_strategy: "none", not_undoable_reason: "snapshot_too_large")
      expect(set.snapshot).to eq("v" => 1, "dropped" => { "merges" => 1 })

      # Later entries are only counted.
      context.add_merge_step!({ "source" => { "id" => 2 } })
      context.note_redo_merges!([ { "source_id" => 1, "target_id" => 2 } ])
      expect(set.reload.snapshot).to eq("v" => 1, "dropped" => { "merges" => 2, "redo_merges" => 1 })
    end
  end

  describe "#undoable?" do
    let(:set) do
      described_class.create!(uuid: SecureRandom.uuid, kind: "graph.edit", undo_strategy: "audit", undoable_until: 1.day.from_now)
    end

    it "is true inside the window" do
      expect(set.undoable?).to be(true)
    end

    it "is false once undone, after the window or for a none set" do
      expect(set.undoable?(2.days.from_now)).to be(false)
      set.update!(undone_at: Time.current)
      expect(set.undoable?).to be(false)
      none = described_class.create!(uuid: SecureRandom.uuid, kind: "graph.delete", undo_strategy: "none",
                                     not_undoable_reason: "hard_delete")
      expect(none.undoable?).to be(false)
    end

    it "validates the strategy and the reason" do
      expect(described_class.new(uuid: "x", kind: "merge", undo_strategy: "magic")).not_to be_valid
      expect(described_class.new(uuid: "x", kind: "merge", not_undoable_reason: "because")).not_to be_valid
    end
  end
end
