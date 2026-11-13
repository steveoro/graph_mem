# frozen_string_literal: true

require "rails_helper"

# Fact supersede F4: applying an "Outdated by a fact" row re-checks everything and is undoable.
RSpec.describe CompactionReviewApplier::FactSupersede do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.") }
  let!(:fact) { fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]) }
  let(:row) do
    FactSupersedeJob.perform_now(fact.id)
    MaintenanceReportRow.find_by!(kind: "fact_supersede")
  end

  def apply(params = {}) = Current.set(actor: FactSupersedeHelpers::OPERATOR_ACTOR) { CompactionReviewService.apply(row.row_uuid, params) }

  it "supersedes with the replacement, records the fact, and undo restores status, superseded_by and outdated_by" do
    result = apply(fact_action: "supersede", replacement: "The MCP server runs on the mcp gem.")

    expect(result).to include(success: true)
    replacement = MemoryObservation.find_by!(content: "The MCP server runs on the mcp gem.")
    expect(old.reload).to have_attributes(status: "superseded", superseded_by_id: replacement.id, outdated_by_id: fact.id,
                                          obsolescence_reason: "Outdated by source fact ##{fact.id}")
    expect(replacement.memory_entity_id).to eq(widget.id)
    expect(ChangeSet.find_by!(uuid: result[:change_set_uuid]).kind).to eq("review.apply")

    ChangeSetUndo.call(result[:change_set_uuid], actor: FactSupersedeHelpers::OPERATOR_ACTOR)
    expect(old.reload).to have_attributes(status: "active", superseded_by_id: nil, outdated_by_id: nil, obsoleted_at: nil)
    expect(MemoryObservation.exists?(replacement.id)).to be false
    expect(row.reload.status).to eq("active")
  end

  it "retires without a replacement (the default when the row has none)" do
    expect(apply).to include(success: true, message: start_with("Retired observation ##{old.id}"))
    expect(old.reload).to have_attributes(status: "obsolete", outdated_by_id: fact.id, superseded_by_id: nil)
  end

  it "re-checks the row under its lock before retiring, so a concurrent edit isn't overwritten" do
    stale = described_class.plan(row.effective_payload.with_indifferent_access, {})
    replacement = old.supersede!({ content: "The MCP server runs on fast-mcp 2." })
    allow(described_class).to receive(:plan).and_return(stale)

    expect(apply).to include(success: false, error: include("no longer active"))
    expect(old.reload).to have_attributes(status: "superseded", superseded_by_id: replacement.id, outdated_by_id: nil)
  end

  it "supersedes with the fact's text when asked to supersede without one" do
    apply(fact_action: "supersede")

    expect(old.reload.superseded_by.content).to eq(fact.content)
  end

  # 1.86.0 (B2): the production chain started with a byte-identical copy of a same-entity fact, which
  # GC then deleted as a duplicate. The fact itself is the replacement: no twin.
  context "when the fact is on the observation's own entity" do
    let!(:own_fact) { fs_fact!(widget, "SynthWidget's MCP server runs on the mcp gem.") }
    let(:own_row) do
      item = { id: SecureRandom.uuid, kind: "fact_supersede", fact_observation_id: own_fact.id, observation_id: old.id,
               verdict: "outdated", confidence: 0.9 }
      CompactionReviewService.seed_report(report_type: "compaction_review", source: "fact_supersede", items: [ item ]).sole
    end

    def apply_own(params) = Current.set(actor: FactSupersedeHelpers::OPERATOR_ACTOR) { CompactionReviewService.apply(own_row.row_uuid, params) }

    it "supersedes by the fact itself when no replacement text is given, and undo restores the observation" do
      expect { @result = apply_own(fact_action: "supersede") }.not_to change(MemoryObservation, :count)

      expect(@result).to include(success: true, message: include("##{old.id}", "##{own_fact.id}"))
      expect(old.reload).to have_attributes(status: "superseded", superseded_by_id: own_fact.id, outdated_by_id: own_fact.id)
      expect(own_fact.reload).to have_attributes(status: "active", content: "SynthWidget's MCP server runs on the mcp gem.")

      expect(ChangeSetUndo.call(@result[:change_set_uuid], actor: FactSupersedeHelpers::OPERATOR_ACTOR)).to be_ok
      expect(old.reload).to have_attributes(status: "active", superseded_by_id: nil, outdated_by_id: nil, obsoleted_at: nil)
      expect(own_fact.reload).to be_active
    end

    it "makes no twin either when the given replacement is the fact's text with extra spaces, and says so in the preview" do
      params = { fact_action: "supersede", replacement: "  #{own_fact.content}  " }
      expect(CompactionReviewApplier.preview(own_row, params)[:effects].first).to include("##{own_fact.id}", "no copy")

      expect { apply_own(params) }.not_to change(MemoryObservation, :count)
      expect(old.reload.superseded_by_id).to eq(own_fact.id)
    end
  end

  it "refuses a changed fact, an inactive observation, another project and a kept statement" do
    row
    fact.update_active!(tags: [])
    expect(apply).to include(success: false, error: include("no longer an active source fact"))

    fact.update_active!(tags: [ "source-fact" ])
    old.mark_obsolete!
    expect(apply).to include(success: false, error: include("no longer active"))
  end

  it "refuses a cross-project pair and a statement the guard now keeps" do
    row
    legacy = fs_project!("Legacy Gadget")
    widget.update!(project_id: legacy.id)
    expect(apply).to include(success: false, error: include("another project"))

    widget.update!(project_id: gadget.id)
    old.update_active!(content: "Legacy Gadget runs on fast-mcp.")
    expect(apply).to include(success: false, error: start_with("Kept: the observation names another project"))
    expect(old.reload).to be_active
  end

  it "applies an unscoped neighbour by hand, without outdated_by, with a warning in the preview" do
    loose = MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")
    MemoryRelation.create!(from_entity: gadget, to_entity: loose, relation_type: "depends_on")
    neighbour = fs_observe!(loose, "Alpha Service talks to fast-mcp.")
    FactSupersedeJob.perform_now(fact.id)
    loose_row = MaintenanceReportRow.where(kind: "fact_supersede").find { |entry| entry.payload["observation_id"] == neighbour.id }

    expect(CompactionReviewApplier.preview(loose_row, {})[:warnings]).to include(include("no project"))
    Current.set(actor: FactSupersedeHelpers::OPERATOR_ACTOR) { CompactionReviewService.apply(loose_row.row_uuid, {}) }
    expect(neighbour.reload).to have_attributes(status: "obsolete", outdated_by_id: nil, obsolescence_reason: include("outside the project"))
  end

  it "previews the effect without writing, and refuses edits of the row" do
    preview = CompactionReviewApplier.preview(row, { fact_action: "supersede", replacement: "The MCP server runs on the mcp gem." })

    expect(preview).to include(ok: true, effects: include(start_with("Supersedes ##{old.id}")))
    expect(old.reload).to be_active
    expect(CompactionReviewService.edit_item(row.row_uuid, { observation_id: fact.id })).to include(success: false, error: include("can't be edited"))
  end

  it "is dangling once the fact loses its tag or either side is inactive" do
    expect(ReviewPolicies::DanglingCheck.reason(row)).to be_nil
    fact.update_active!(tags: [])
    expect(ReviewPolicies::DanglingCheck.reason(row)).to include("no longer a source fact")
    fact.update_active!(tags: [ "source-fact" ])
    old.mark_obsolete!
    expect(ReviewPolicies::DanglingCheck.reason(row)).to include("no longer active")
  end
end
