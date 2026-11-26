# frozen_string_literal: true

require "rails_helper"

# Dream State R1b "done when", on a synthetic graph, through whole dream-state runs (jobs): the
# run queues the library's swap, the operator applies it, and two more runs create no part_of and
# queue no orphan row for it. Every edge a run writes carries the run's actor in its audit row.
RSpec.describe "Dream state: a library's part_of swapped for the project's depends_on", type: :integration do
  include ActiveJob::TestHelper

  let!(:synth_app) { fs_project!("SynthApp") }
  let!(:library) { fs_member!(synth_app, "SynthLib", "Gem") }
  let!(:children) { [ fs_member!(library, "SynthLib Notes", "Documentation"), fs_member!(library, "SynthLib Config", "Configuration") ] }
  let(:operator) { "operator:synth@127.0.0.1" }

  before do
    clear_enqueued_jobs
    AppSettings.enable_dream_state_compactor = true
    fs_observe!(synth_app, "SynthApp uses SynthLib to parse its feeds.")
  end

  after do
    clear_enqueued_jobs
    CompactionRun.delete_all
  end

  def full_run
    run = CompactionRunner.start_or_resume!
    drain_compaction_jobs!
    expect(run.reload.status).to eq("completed")
    run
  end

  def library_rows(kinds) = MaintenanceReportRow.where(kind: kinds).select { |row| row.anchor_entity_id == library.id }

  it "queues the swap, and after it is applied two runs leave the library global with no part_of and no orphan row" do
    run = full_run

    swap = MaintenanceReportRow.find_by!(kind: "relation_retype")
    expect(swap.payload).to include("operation" => "swap", "from_entity_id" => library.id, "to_entity_id" => synth_app.id)
    expect(swap.payload.dig("evidence", "facts").map { |fact| fact["content"] }).to eq([ "SynthApp uses SynthLib to parse its feeds." ])
    expect(run.stats["dependency_swaps_queued"]).to eq(1)

    expect(Current.set(actor: operator) { CompactionReviewService.apply(swap.row_uuid) }).to include(success: true)
    expect(MemoryRelation.exists?(from_entity_id: synth_app.id, to_entity_id: library.id, relation_type: "depends_on")).to be(true)
    expect(([ library ] + children).map { |entity| entity.reload.project_id }).to eq([ nil, nil, nil ])

    2.times do
      later = full_run
      expect(later.stats.values_at("orphans_parented", "orphans_queued", "dependency_swaps_queued", "dependency_adds_queued").map(&:to_i))
        .to eq([ 0, 0, 0, 0 ])
    end

    expect(MemoryRelation.where(from_entity_id: library.id, relation_type: "part_of")).not_to exist
    expect(library_rows(%w[orphan_parent relation_retype])).to eq([ swap ])
    expect(([ library ] + children).map { |entity| entity.reload.project_id }).to eq([ nil, nil, nil ])
    expect(ProjectIdBackfill.new(out: StringIO.new).run.changed).to eq(0)
  end

  it "writes every edge of a run with the actor compaction:<run id>" do
    orphan = MemoryEntity.create!(name: "SynthApp_task", entity_type: "Task")
    widget = fs_member!(synth_app, "SynthWidget", "Component")
    variant = MemoryRelation.create!(from_entity: widget, to_entity: orphan, relation_type: "synth_placeholder")
    variant.update_column(:relation_type, "Has Many")
    since = AuditLog.maximum(:id).to_i

    run = full_run

    expect(MemoryRelation.find(variant.id).relation_type).to eq("has_many")
    expect(MemoryRelation.exists?(from_entity_id: orphan.id, to_entity_id: synth_app.id, relation_type: "part_of")).to be(true)
    edge_audits = AuditLog.where(auditable_type: "MemoryRelation").where("id > ?", since)
    expect(edge_audits.pluck(:action)).to include("create", "update")
    expect(edge_audits.pluck(:actor).uniq).to eq([ "compaction:#{run.id}" ])
    expect(ChangeSet.where(actor: "compaction:#{run.id}").pluck(:kind)).to contain_exactly("dream.relation_types", "compaction.auto_parent")
  end
end
