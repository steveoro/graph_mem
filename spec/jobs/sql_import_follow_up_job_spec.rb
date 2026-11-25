# frozen_string_literal: true

require "rails_helper"

# The follow-up of an SQL import (SqlImport::FollowUp, run by this job) on real imports of a SynthPrj
# script: each step, the near-duplicate check when the embedding service is down, the compaction
# condition, the embeddings-lock retry, full maintenance and the stale scan's contradiction hook.
RSpec.describe SqlImportFollowUpJob do
  include ActiveSupport::Testing::TimeHelpers

  let!(:project) { fs_project!("SynthPrj") }
  let!(:widget) { fs_member!(project, "SynthWidget", "Component") }

  # Imports the script as the import page and the rake task do; returns the `import` operation.
  def import!(script, full_maintenance: false)
    SqlImport::Flow.finish(sql_import(script), file_name: "synth_prj.sql", full_maintenance: full_maintenance)
  end

  def follow_up(operation) = operation.reload.details["follow_up"]

  # A script whose widget fact comes back as a new row next to a reworded local copy.
  def reworded_duplicate_script
    fs_observe!(widget, "Restated: SynthWidget renders tiles.")
    sql_export(project).tap do
      MemoryObservation.where(memory_entity_id: widget.id).delete_all
      fs_observe!(widget, "SynthWidget renders tiles.")
    end
  end

  it "recomputes trust, requests keyword paths, queues new source facts and records the contradiction ids" do
    fs_observe!(widget, "SynthWidget renders tiles.", confidence: 0.9)
    fs_fact!(widget, "SynthWidget uses the synthetic renderer.")
    script = sql_export(project)
    MemoryObservation.where(memory_entity_id: widget.id).delete_all
    operation = import!(script)
    imported = widget.memory_observations.find_by!(content: "SynthWidget renders tiles.")
    expect(SqlImportFollowUpJob).to have_been_enqueued.with(operation.operation_id)
    expect(imported.trust_score).to eq(0)
    FactKeywordsJob.reset_request! # the setup's facts asked for a run a moment ago

    expect { described_class.perform_now(operation.operation_id) }
      .to have_enqueued_job(FactKeywordsJob).and have_enqueued_job(FactSupersedeJob).exactly(:once)

    expect(imported.reload.trust_score).to eq(ObservationTrustRanker.rank(imported)).and be_positive
    expect(follow_up(operation)).to include("status" => "done", "embeddings" => { "skipped" => "vectors_off" }, "keywords_requested" => true,
                                            "fact_supersede_queued" => 1, "review_rows" => {}, "compaction" => "not_needed")
    expect(operation.details["contradiction_entity_ids"]).to eq([ widget.id ])
    expect([ CompactionRun.count, OperationProgress.where(operation_type: "scheduled_run").count ]).to eq([ 0, 0 ])
    expect(SqlImport::FollowUp.contradiction_entity_ids(after: 1.minute.ago)).to eq([ widget.id ])
    expect(SqlImport::FollowUp.contradiction_entity_ids(after: 1.minute.from_now)).to be_empty
  end

  it "queues a fact that gained the source-fact tag, reading the field names the script records" do
    fact = travel_to(2.days.ago) { fs_observe!(widget, "SynthWidget uses the synthetic renderer.", source: "docs:README.md") }
    fact.update_columns(tags: [ SourceFact::SOURCE_FACT_TAG ], updated_at: Time.current)
    script = sql_export(project)
    fact.update_columns(tags: [], updated_at: 2.days.ago)
    operation = OperationProgress.find_by!(operation_id: sql_import(script).operation_id) # as a run without the app's record

    expect(operation.details["affected"]).to contain_exactly(include("id" => fact.id, "action" => "updated", "fields" => [ "tags" ]))
    expect { described_class.perform_now(operation.operation_id) }.to have_enqueued_job(FactSupersedeJob).with(fact.id)
    expect(follow_up(operation)).to include("fact_supersede_queued" => 1)
  end

  it "seeds an entity_merge row per name or alias collision, then starts compaction (unless it is off)" do
    fs_member!(project, "SynthGadget", "Component", aliases: "Gadget")
    script = sql_export(project)
    old = MemoryEntity.find_by!(name: "SynthGadget")
    old.update_columns(name: "SynthGadget Old", aliases: "SynthGadget")
    twin = fs_member!(project, "SynthGadget Twin", "Component", aliases: "SynthGadget")
    operation = import!(script)
    copy = MemoryEntity.find_by!(name: "SynthGadget", project_id: project.id)

    expect { described_class.perform_now(operation.operation_id) }.to have_enqueued_job(DreamStateCompactionJob).and have_enqueued_job(ReviewPolicyJob)

    rows = MaintenanceReportRow.where(kind: "entity_merge")
    expect(rows.map { |row| row.payload.values_at("entity_a", "entity_b").map { |entity| entity["entity_id"] }.sort })
      .to contain_exactly([ copy.id, old.id ].sort, [ copy.id, twin.id ].sort)
    expect(rows.first.maintenance_report.data).to include("source" => "sql_import", "source_ref" => operation.operation_id)
    expect(follow_up(operation)).to include("review_rows" => { "entity_merge" => 2 }, "compaction" => "started", "compaction_run_id" => CompactionRun.sole.id)
  end

  it "leaves compaction to its schedule when it is switched off, and says so" do
    fs_member!(project, "SynthGadget", "Component")
    script = sql_export(project)
    MemoryEntity.find_by!(name: "SynthGadget").update_columns(name: "SynthGadget Old", aliases: "SynthGadget")
    fs_member!(project, "SynthGadget Twin", "Component", aliases: "SynthGadget")
    allow(AppSettings).to receive(:dream_state_compactor_enabled?).and_return(false)

    described_class.perform_now(import!(script).operation_id)

    expect(OperationProgress.find_by!(operation_type: "import").details.dig("follow_up", "compaction")).to eq("off")
    expect(CompactionRun.count).to eq(0)
  end

  it "backfills the embeddings outside the membership lock, then proposes a reworded duplicate", :with_test_embeddings do
    calls = record_embedding_calls!
    script = reworded_duplicate_script
    kept = widget.memory_observations.find_by!(content: "SynthWidget renders tiles.")
    operation = import!(script)
    imported = widget.memory_observations.find_by!(content: "Restated: SynthWidget renders tiles.")
    expect(imported.embedded_at).to be_nil

    described_class.perform_now(operation.operation_id)

    expect(imported.reload.embedded_at).to be_present
    expect(MaintenanceReportRow.find_by!(kind: "delete_observation").payload)
      .to include("observation_id" => imported.id, "similar_observation_id" => kept.id, "cosine_distance" => 0.0)
    expect(follow_up(operation)).to include("embeddings" => include("observations" => be_positive), "compaction" => "started",
                                            "near_duplicates" => { "checked" => 1, "unchecked" => 0 })
    expect(calls).to all(include(held: false))
  end

  it "compares new facts only with the facts that were there before the import, not with each other", :with_test_embeddings do
    record_embedding_calls!
    fs_observe!(widget, "SynthWidget renders tiles.")
    fs_observe!(widget, "Restated: SynthWidget renders tiles.")
    script = sql_export(project)
    sql_delete_tree!(project) # a fresh target: both rewordings come in as new rows
    operation = import!(script)

    described_class.perform_now(operation.operation_id)

    expect(MaintenanceReportRow.where(kind: "delete_observation")).to be_empty
    expect(follow_up(operation)).to include("near_duplicates" => { "checked" => 2, "unchecked" => 0 }, "compaction" => "not_needed")
  end

  it "reports a near-duplicate check that couldn't run because the embedding service is down", :with_test_embeddings do
    operation = import!(reworded_duplicate_script)

    described_class.perform_now(operation.operation_id)

    expect(follow_up(operation)).to include("status" => "done", "embeddings" => include("skipped" => "unavailable"),
                                            "near_duplicates" => { "checked" => 0, "unchecked" => 1, "reason" => "unavailable" })
    expect(MaintenanceReportRow.where(kind: "delete_observation")).to be_empty
  end

  it "runs again while another backfill holds the embeddings lock, and goes on at the last attempt", :with_test_embeddings do
    record_embedding_calls!
    operation = import!(sql_export(project))
    stub_const("SqlImportEmbeddingsLockHolder", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    SqlImportEmbeddingsLockHolder.establish_connection(ActiveRecord::Base.connection_db_config)
    holder = SqlImportEmbeddingsLockHolder.connection
    lock = holder.quote("#{EmbeddingService::EMBEDDING_LOCK_PREFIX}:#{holder.current_database}:embeddings")
    holder.select_value("SELECT GET_LOCK(#{lock}, 0)")

    expect { described_class.perform_now(operation.operation_id) }.to have_enqueued_job(described_class).with(operation.operation_id, 2)
    expect(follow_up(operation)).to include("status" => "queued", "deferred" => 1)

    expect(described_class.perform_now(operation.operation_id, described_class::MAX_ATTEMPTS)).to eq(:done)
    expect(follow_up(operation)).to include("status" => "done", "embeddings" => include("skipped" => "lock_busy"))
  ensure
    holder&.select_value("SELECT RELEASE_LOCK(#{lock})")
    SqlImportEmbeddingsLockHolder.connection_pool.disconnect! if defined?(SqlImportEmbeddingsLockHolder)
  end

  it "starts one scheduled run (trigger sql_import) instead of compaction when full maintenance is asked for" do
    operation = import!(sql_export(project), full_maintenance: true)

    described_class.perform_now(operation.operation_id)

    expect(OperationProgress.where(operation_type: "scheduled_run").sole.details["trigger"]).to eq(ScheduledRunJob::TRIGGER_SQL_IMPORT)
    expect(operation.reload.details).to include("full_maintenance_outcome" => "started")
    expect(follow_up(operation)["compaction"]).to eq("full_maintenance")
  end

  it "starts nothing when a scheduled run is already going, and says so" do
    ScheduledRunJob.start!
    operation = import!(sql_export(project), full_maintenance: true)

    described_class.perform_now(operation.operation_id)

    expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(1)
    expect(operation.reload.details["full_maintenance_outcome"]).to eq("already_running")
  end

  it "reads the written rows from the audit log once the operation's list is capped" do
    script = sql_export(project)
    sql_delete_tree!(project)
    operation = import!(script)
    operation.update!(details: operation.details.merge("affected" => [], "affected_count" => 5_001))

    touched = SqlImport::Touched.for(operation)

    expect(touched.written_entity_ids).to match_array(MemoryEntity.where(name: %w[SynthPrj SynthWidget]).ids)
  end

  it "makes the stale scan's contradiction pass look at the imported facts, whose updated_at is the source's", :with_test_embeddings do
    travel_to(2.days.ago) { fs_observe!(widget, "SynthWidget renders tiles.") }
    script = sql_export(project)
    MemoryObservation.where(memory_entity_id: widget.id).delete_all
    described_class.perform_now(import!(script).operation_id)
    allow(StaleMemoryScanner).to receive(:previous_watermark).and_return(1.hour.ago)
    allow(ContradictionDetector).to receive(:scan).and_call_original

    StaleMemoryScanner.detect_contradictions

    expect(ContradictionDetector).to have_received(:scan).with(widget.id)
  end
end
