# frozen_string_literal: true

require "rails_helper"

# R1a: the dream-state phase `relation_types` runs RelationTypeSweep first in every run, one batch
# per job, with its own cursor over relation ids.
RSpec.describe DreamStateCompactor::RelationTypesPhase do
  include ActiveJob::TestHelper

  let(:suffix) { SecureRandom.hex(3) }
  let(:project) { MemoryEntity.create!(name: "Alpha Project #{suffix}", entity_type: "Project") }
  let(:service) { MemoryEntity.create!(name: "SynthService #{suffix}", entity_type: "Service") }

  after { CompactionRun.delete_all }

  def stored_relation(from, to, stored_type)
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder_#{SecureRandom.hex(4)}")
    relation.update_column(:relation_type, stored_type)
    relation
  end

  def widgets(count)
    Array.new(count) { |index| MemoryEntity.create!(name: "SynthWidget #{suffix} #{index}", entity_type: "Component") }
  end

  it "is the first phase, before the entity phases" do
    expect(CompactionRun::PHASES).to eq(%w[relation_types dependency_edges orphans tree_walk relationship_discovery])
    expect(CompactionTraversal.new.next_phase_after("relation_types")).to eq("dependency_edges")
    expect(CompactionRunner.acquire_run!.phase).to eq("relation_types")
  end

  it "walks relations by id cursor in batches, then moves on to dependency_edges with one report for the run" do
    stub_const("RelationTypeSweep::BATCH_SIZE", 2)
    variants = widgets(3).map { |widget| stored_relation(service, widget, "requires") }
    queued = stored_relation(service, project, "child_of")
    run = CompactionRunner.acquire_run!
    compactor = DreamStateCompactor.new(run: run)

    expect(compactor.process_batch!).to eq(:continued)
    expect(run.reload).to have_attributes(phase: "relation_types", cursor_entity_id: nil)
    expect(run.stats).to include("relation_cursor_id" => variants[1].id, "relations_processed" => 2, "relation_types_fixed" => 2)

    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:continued)
    expect(run.reload.phase).to eq("relation_types")
    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:continued)

    run.reload
    expect(run.phase).to eq("dependency_edges")
    expect(run.stats).to include("relations_processed" => 4, "relation_types_fixed" => 3, "relation_retypes_queued" => 1)
    expect(variants.map { |variant| variant.reload.relation_type }).to all(eq("depends_on"))
    expect(queued.reload.relation_type).to eq("child_of")
    report = MaintenanceReport.find(run.stats["relation_types_report_id"])
    expect(report.data).to include("source" => "dream_state", "source_ref" => run.id, "actor" => "compaction:#{run.id}")
    expect(report.data["finished_at"]).to be_present
    expect(report.data["counts"]).to include("scanned" => 4, "retyped" => 3, "queued" => 1)
    expect(MaintenanceReport.where(report_type: "relation_type_sweep").count).to eq(1)
    expect(ChangeSet.where(kind: "dream.relation_types").pluck(:actor).uniq).to eq([ "compaction:#{run.id}" ])
    expect(run.operation_progress.reload.current_count).to eq(4)
  end

  it "pauses after a batch when a pause was requested, and resumes from the relation cursor" do
    stub_const("RelationTypeSweep::BATCH_SIZE", 1)
    first, second = widgets(2).map { |widget| stored_relation(service, widget, "requires") }
    run = CompactionRunner.acquire_run!
    allow(RelationTypeSweep).to receive(:new).and_wrap_original do |original, **kwargs|
      run.update!(pause_requested: true)
      original.call(**kwargs)
    end

    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:paused)
    expect(run.reload).to be_paused
    expect(run.stats["relation_cursor_id"]).to eq(first.id)
    expect(second.reload.relation_type).to eq("requires")

    CompactionRunner.acquire_run!
    allow(RelationTypeSweep).to receive(:new).and_call_original
    DreamStateCompactor.new(run: run.reload).process_batch!
    expect(second.reload.relation_type).to eq("depends_on")
    expect(run.reload.stats["relations_processed"]).to eq(2)
  end

  it "lets a run created before the phase existed continue from its own phase" do
    variant = stored_relation(service, project, "requires")
    run = CompactionRun.create!(status: "running", phase: "relationship_discovery", stats: { "entities_processed" => 5 },
                                started_at: Time.current)

    DreamStateCompactionJob.new.perform(run.id)
    drain = 0
    while run.reload.running? && drain < 20
      DreamStateCompactionJob.new.perform(run.id)
      drain += 1
    end

    expect(run.reload).to be_completed
    expect(run.stats).not_to have_key("relations_processed")
    expect(variant.reload.relation_type).to eq("requires")
  end

  it "runs the pre-flight integrity sweep once per run, not once per relation batch" do
    stub_const("RelationTypeSweep::BATCH_SIZE", 1)
    widgets(3).each { |widget| stored_relation(service, widget, "requires") }
    run = CompactionRunner.acquire_run!
    allow(GraphIntegrityService).to receive(:call).and_call_original

    3.times { DreamStateCompactionJob.new.perform(run.id) }

    expect(GraphIntegrityService).to have_received(:call).once
    expect(run.reload.stats).to include("integrity_sweep_done" => true, "relations_processed" => 3)
  end
end
