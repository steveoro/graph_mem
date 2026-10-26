# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReviewGroupActions do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let(:group) { "mixed|spec" }

  def target(i) = MemoryEntity.create!(name: "Beta Service #{i}", entity_type: "Component")

  def row(kind, payload, status: "active", confidence: 0.9, priority: 50, group_key: group)
    MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: SecureRandom.uuid, kind: kind, status: status,
                                 signature: "#{kind}|#{SecureRandom.hex(4)}", payload: payload, group_key: group_key,
                                 confidence: confidence, priority: priority)
  end

  def proposal(**attrs)
    row("relationship_proposal", { "from_entity_id" => widget.id, "to_entity_id" => target(SecureRandom.hex(2)).id,
                                   "relation_type" => "depends_on" }, **attrs)
  end

  def uuids(list) = list.map { |entry| entry[:row_uuid] }

  describe "apply" do
    it "excludes destructive and choice kinds, low confidence and non-pending rows, and applies only what the preview listed" do
      safe = proposal(priority: 80)
      weak = proposal(confidence: 0.5)
      merge = row("entity_merge", { "entity_a" => { "entity_id" => widget.id }, "entity_b" => { "entity_id" => target(1).id } })
      pair = row("contradiction", { "observation_id_1" => 1, "observation_id_2" => 2 })
      proposal(status: "dismissed")

      preview = described_class.preview(group_key: group, op: "apply", min_confidence: 0.8)

      expect(uuids(preview[:included])).to eq([ safe.row_uuid ])
      expect(preview[:excluded].to_h { |entry| [ entry[:row_uuid], entry[:reason] ] }).to eq(
        weak.row_uuid => "below confidence 0.8", merge.row_uuid => "destructive: apply one by one",
        pair.row_uuid => "choose a side per row"
      )

      result = described_class.apply(group_key: group, row_uuids: uuids(preview[:included]), token: preview[:token], min_confidence: 0.8)

      expect(result).to include(success: true, status: :ok, message: "Applied 1 suggestion(s)", undoable: true)
      expect(safe.reload.status).to eq("approved")
      expect([ weak, merge, pair ].map { |r| r.reload.status }).to eq(%w[active active active])
      set = ChangeSet.find_by!(uuid: result[:change_set_uuid])
      expect(set.kind).to eq("review.group_apply")
      expect(ChangeSetUndo.call(set.uuid, actor: "operator:steve@127.0.0.1")).to be_ok
      expect(safe.reload.status).to eq("active")
    end

    it "answers a conflict and writes nothing when the group changed since the preview" do
      proposal
      preview = described_class.preview(group_key: group, op: "apply")
      newcomer = proposal

      result = described_class.apply(group_key: group, row_uuids: uuids(preview[:included]), token: preview[:token])

      expect(result).to include(success: false, status: :conflict, changed: [ newcomer.row_uuid ])
      expect(MaintenanceReportRow.where(status: "approved")).not_to exist
      expect(ChangeSet.count).to eq(0)
    end

    it "leaves snoozed rows out of apply (restore them first)" do
      safe = proposal
      snoozed = proposal(status: "ignored")

      preview = described_class.preview(group_key: group, op: "apply")
      described_class.apply(group_key: group, row_uuids: uuids(preview[:included]), token: preview[:token])

      expect(preview[:excluded].sole).to include(row_uuid: snoozed.row_uuid, reason: "snoozed: restore it first")
      expect([ safe.reload.status, snoozed.reload.status ]).to eq(%w[approved ignored])
    end

    it "succeeds with an undoable set when only some rows fail, and fails with an error when all do" do
      kept = proposal(priority: 90)
      broken = proposal(priority: 10)
      preview = described_class.preview(group_key: group, op: "apply")
      MemoryEntity.find(broken.payload["to_entity_id"]).destroy!

      result = described_class.apply(group_key: group, row_uuids: uuids(preview[:included]), token: preview[:token])

      expect(result).to include(success: true, message: "Applied 1 suggestion(s); 1 failed", undoable: true)
      expect([ kept.reload.status, broken.reload.status ]).to eq(%w[approved active])

      preview = described_class.preview(group_key: group, op: "apply")
      failed = described_class.apply(group_key: group, row_uuids: uuids(preview[:included]), token: preview[:token])
      expect(failed).to include(success: false, error: "Applied 0 suggestion(s); 1 failed")
    end

    it "stops on a busy lock after the first write and says how many rows are left; before any write it raises" do
      rows = [ proposal(priority: 90), proposal(priority: 50), proposal(priority: 10) ]
      preview = described_class.preview(group_key: group, op: "apply")
      calls = 0
      allow(CompactionReviewService).to receive(:apply).and_wrap_original do |original, *args, **kwargs|
        (calls += 1) == 2 ? raise(ProjectMembership::LockTimeout, "synthetic") : original.call(*args, **kwargs)
      end

      result = described_class.apply(group_key: group, row_uuids: uuids(preview[:included]), token: preview[:token])

      expect(result).to include(success: true, undoable: true,
                                message: "Applied 1 suggestion(s); 2 not processed (the database was busy: retry them)")
      expect(rows.map { |r| r.reload.status }).to eq(%w[approved active active])

      allow(CompactionReviewService).to receive(:apply).and_raise(ProjectMembership::LockTimeout, "synthetic")
      preview = described_class.preview(group_key: group, op: "apply")
      expect { described_class.apply(group_key: group, row_uuids: uuids(preview[:included]), token: preview[:token]) }
        .to raise_error(ProjectMembership::LockTimeout)
    end

    it "refuses a group with nothing bulk-applicable" do
      row("delete_entity", { "entity_id" => widget.id })
      preview = described_class.preview(group_key: group, op: "apply")

      expect(described_class.apply(group_key: group, row_uuids: [], token: preview[:token])).to include(status: :unprocessable)
      expect(MemoryEntity.exists?(widget.id)).to be(true)
    end

    it "caps a group action at 100 rows, highest priority first" do
      stub_const("ReviewGroupActions::GROUP_CAP", 2)
      rows = [ proposal(priority: 10), proposal(priority: 90), proposal(priority: 50) ]

      preview = described_class.preview(group_key: group, op: "apply")

      expect(uuids(preview[:included])).to eq([ rows[1].row_uuid, rows[2].row_uuid ])
      expect(preview[:excluded].sole).to include(row_uuid: rows[0].row_uuid, reason: "over the cap of 2")
    end
  end

  describe "dismiss and snooze" do
    it "include every kind (contradiction too) but only pending rows, in one undoable set" do
      pair = row("contradiction", { "observation_id_1" => 1, "observation_id_2" => 2 })
      merge = row("entity_merge", { "entity_a" => { "entity_id" => widget.id }, "entity_b" => { "entity_id" => target(2).id } })
      resolved = proposal(status: "approved")

      result = described_class.dismiss(group_key: group, row_uuids: [ pair, merge, resolved ].map(&:row_uuid), reason: "synthetic")

      expect(result).to include(success: true, message: "Dismissed 2 suggestion(s)", undoable: true)
      expect([ pair.reload.status, merge.reload.status, resolved.reload.status ]).to eq(%w[dismissed dismissed approved])
      expect(ChangeSet.find_by!(uuid: result[:change_set_uuid]).kind).to eq("review.group_dismiss")
      expect(ChangeSetUndo.call(result[:change_set_uuid], actor: "operator:steve@127.0.0.1")).to be_ok
      expect([ pair.reload.status, merge.reload.status ]).to eq(%w[active active])
    end

    it "snoozes with expiring suppressions, but keeps a permanent one" do
      fresh = proposal
      dismissed_twin = proposal
      MaintenanceReportSuppression.create!(report_type: "compaction_review", signature: dismissed_twin.signature, source: "dismissed")

      result = described_class.snooze(group_key: group, row_uuids: [ fresh, dismissed_twin ].map(&:row_uuid), days: 7)

      expect(result).to include(success: true, message: "Snoozed 2 suggestion(s)")
      expect(ChangeSet.find_by!(uuid: result[:change_set_uuid]).kind).to eq("review.group_snooze")
      expect(MaintenanceReportSuppression.find_by!(signature: fresh.signature)).to have_attributes(source: "snoozed")
      expect(MaintenanceReportSuppression.find_by!(signature: dismissed_twin.signature)).to have_attributes(source: "dismissed", expires_at: nil)
    end

    it "refuses when no selected row is pending" do
      resolved = proposal(status: "dismissed")

      expect(described_class.snooze(group_key: group, row_uuids: [ resolved.row_uuid ])).to include(success: false, status: :unprocessable)
    end
  end
end
