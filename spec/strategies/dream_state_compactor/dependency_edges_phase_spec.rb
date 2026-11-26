# frozen_string_literal: true

require "rails_helper"

# Dream State R1b: the phase `dependency_edges` queues a relation_retype "swap" row for each
# part_of edge from a dependency-like entity to a Project, with its evidence.
RSpec.describe DreamStateCompactor::DependencyEdgesPhase do
  let!(:synth_app) { fs_project!("SynthApp") }
  let!(:library) { fs_member!(synth_app, "SynthLib", "Gem") }

  after { CompactionRun.delete_all }

  def phase_run = CompactionRun.create!(status: "running", phase: "dependency_edges", stats: {}, started_at: Time.current)

  def swap_rows = MaintenanceReportRow.where(kind: "relation_retype").select { |row| row.payload["operation"] == "swap" }

  it "runs after relation_types and before orphans, without the membership lock" do
    expect(CompactionRun::PHASES).to eq(%w[relation_types dependency_edges orphans tree_walk relationship_discovery])
    expect(CompactionTraversal.new.next_phase_after("relation_types")).to eq("dependency_edges")
    expect(CompactionTraversal.new.next_phase_after("dependency_edges")).to eq("orphans")
    expect(DreamStateCompactor.membership_phase?("dependency_edges")).to be(false)
    expect(CompactionRun::ENTITY_PHASES).to eq(%w[orphans tree_walk relationship_discovery])
  end

  it "queues one swap per dependency-like part_of a Project, with the use facts as evidence, and writes nothing else" do
    used = fs_observe!(synth_app, "SynthApp uses SynthLib to parse feeds.")
    fs_observe!(synth_app, "SynthApp ships a command line.")
    fs_observe!(synth_app, "SynthLib is mentioned here, nothing more.")
    held = fs_observe!(library, "It was used for the first importer.")
    tool = fs_member!(synth_app, "SynthCli", "tool")
    fs_member!(synth_app, "SynthService", "Service")
    fs_member!(library, "SynthLib Core", "Framework") # part_of a library, not of a Project
    run = phase_run

    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:continued)

    rows = swap_rows
    expect(rows.map { |row| row.payload["from_entity_id"] }).to contain_exactly(library.id, tool.id)
    row = rows.find { |candidate| candidate.payload["from_entity_id"] == library.id }
    part_of = MemoryRelation.find_by!(from_entity_id: library.id, relation_type: "part_of")
    expect(row.payload).to include("relation_id" => part_of.id, "to_entity_id" => synth_app.id, "old_type" => "part_of",
                                   "new_type" => "depends_on")
    expect(row.payload["evidence"]).to eq("entity_type" => "Gem", "facts" => [
      { "observation_id" => used.id, "entity_id" => synth_app.id, "entity_name" => "SynthApp", "content" => used.content },
      { "observation_id" => held.id, "entity_id" => library.id, "entity_name" => "SynthLib", "content" => held.content }
    ])
    expect(run.reload.phase).to eq("orphans")
    expect(run.stats).to include("dependency_swaps_queued" => 2, "dependency_edges_checked" => 2)
    expect(library.reload.project_id).to eq(synth_app.id)
    expect(MemoryRelation.where(relation_type: "depends_on")).not_to exist
  end

  it "finds a fact by its keyword path too, and lists at most three" do
    alias_fact = fs_observe!(synth_app, "The parser gem is used by the importer.")
    alias_fact.update_columns(keywords: %w[SynthApp SynthLib], keywords_at: Time.current)
    4.times { |index| fs_observe!(synth_app, "SynthApp uses SynthLib in step #{index}.") }

    DreamStateCompactor.new(run: phase_run).process_batch!

    facts = swap_rows.sole.payload["evidence"]["facts"]
    expect(facts.size).to eq(DependencyEvidence::MAX_FACTS)
    expect(facts.first["observation_id"]).to eq(alias_fact.id)
  end

  it "never queues a swap again while one is pending, or after it was dismissed" do
    DreamStateCompactor.new(run: phase_run).process_batch!
    second = phase_run
    DreamStateCompactor.new(run: second).process_batch!

    expect(swap_rows.size).to eq(1)
    expect(second.reload.stats["dependency_swaps_queued"].to_i).to eq(0)

    CompactionReviewService.dismiss(swap_rows.sole.row_uuid, reason: "we own it")
    DreamStateCompactor.new(run: phase_run).process_batch!
    expect(swap_rows.size).to eq(1)
  end

  it "queues nothing when the setting is blank, and follows a changed list" do
    AppSettings.dependency_like_types = ""
    DreamStateCompactor.new(run: phase_run).process_batch!
    expect(swap_rows).to be_empty

    AppSettings.dependency_like_types = "Service"
    service = fs_member!(synth_app, "SynthService", "Service")
    DreamStateCompactor.new(run: phase_run).process_batch!
    expect(swap_rows.map { |row| row.payload["from_entity_id"] }).to eq([ service.id ])
  end

  it "walks the edges in batches by relation id and pauses between batches" do
    stub_const("DreamStateCompactor::DependencyEdgesPhase::BATCH_SIZE", 1)
    second = fs_member!(synth_app, "SynthGem", "Gem")
    run = phase_run
    run.update!(pause_requested: true)

    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:paused)
    first_edge = MemoryRelation.find_by!(from_entity_id: library.id, relation_type: "part_of")
    expect(run.reload.stats).to include("dependency_cursor_id" => first_edge.id, "dependency_edges_checked" => 1)

    run.update!(status: "running")
    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:continued)
    expect(run.reload.phase).to eq("dependency_edges")
    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:continued)
    expect(run.reload.phase).to eq("orphans")
    expect(swap_rows.map { |row| row.payload["from_entity_id"] }).to contain_exactly(library.id, second.id)
  end
end
