# frozen_string_literal: true

require "rails_helper"

# Dream State R1c: phase `dependency_edges`' removal pass queues an informational relation_review
# row when a project fact says an entity the Project still depends_on, or holds by part_of, was
# removed, replaced or dropped.
RSpec.describe DreamStateCompactor::RemovalEvidencePass do
  let!(:app) { fs_project!("SynthApp") }
  let!(:library) { MemoryEntity.create!(name: "SynthLib", entity_type: "Gem") }
  let!(:uses) { MemoryRelation.create!(from_entity: app, to_entity: library, relation_type: "depends_on") }

  after { CompactionRun.delete_all }

  def phase_run(stats = {}) = CompactionRun.create!(status: "running", phase: "dependency_edges", stats: stats, started_at: Time.current)

  def review_rows = MaintenanceReportRow.where(kind: "relation_review").order(:id).to_a

  it "queues one row per (relation, fact) with the R1c payload keys, after the swap pass, in the same job" do
    fact = fs_observe!(app, "SynthApp replaced SynthLib with SynthParser in 2.0.")
    fs_observe!(app, "SynthApp uses SynthLib to parse its feeds.")
    run = phase_run

    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:continued)

    row = review_rows.sole
    expect(row.payload.keys).to match_array(%w[kind relation_id relation_type from_entity_id from_name to_entity_id to_name evidence reason])
    expect(row.payload).to include("relation_id" => uses.id, "relation_type" => "depends_on", "from_entity_id" => app.id, "from_name" => "SynthApp",
                                   "to_entity_id" => library.id, "to_name" => "SynthLib")
    expect(row.payload["evidence"]).to eq("observation_id" => fact.id, "entity_id" => app.id, "entity_name" => "SynthApp", "excerpt" => fact.content)
    expect(row.payload["reason"]).to eq("A fact of 'SynthApp' (##{fact.id} on 'SynthApp') says 'SynthLib' was removed, replaced or dropped, " \
                                        "but 'SynthApp' still depends_on it")
    expect(row).to have_attributes(signature: "relation_review|#{uses.id}|#{fact.id}", anchor_entity_id: library.id,
                                   group_key: "relation_review|rel:#{uses.id}")
    expect(run.reload.phase).to eq("orphans")
    expect(run.stats).to include("relation_reviews_queued" => 1, "removal_edges_checked" => 1, "removal_cursor_id" => uses.id,
                                 "dependency_pass" => "removal")
    expect(MemoryRelation.exists?(uses.id)).to be(true)
  end

  it "reads a direct part_of of the Project too, and quotes a cut excerpt of a long fact" do
    widget = fs_member!(app, "SynthWidget", "Component")
    fact = fs_observe!(widget, "SynthWidget was removed from the dashboard. #{'Detail ' * 60}")

    DreamStateCompactor.new(run: phase_run).process_batch!

    row = review_rows.sole
    part_of = MemoryRelation.find_by!(from_entity_id: widget.id, relation_type: "part_of")
    expect(row.payload).to include("relation_id" => part_of.id, "relation_type" => "part_of", "from_name" => "SynthWidget", "to_name" => "SynthApp")
    expect(row.payload["evidence"]["excerpt"]).to eq(fact.content.squish.truncate(RemovalEvidence::EXCERPT_LIMIT))
    expect(row.payload["reason"]).to end_with("but 'SynthApp' still holds it by part_of")
    expect(row.anchor_entity_id).to eq(widget.id)
  end

  it "never queues a row again while it is pending, or after it was dismissed; a new fact gets its own row" do
    fs_observe!(app, "SynthApp dropped SynthLib.")
    DreamStateCompactor.new(run: phase_run).process_batch!
    second = phase_run
    DreamStateCompactor.new(run: second).process_batch!
    expect(review_rows.size).to eq(1)
    expect(second.reload.stats["relation_reviews_queued"].to_i).to eq(0)

    CompactionReviewService.dismiss(review_rows.sole.row_uuid, reason: "still used")
    DreamStateCompactor.new(run: phase_run).process_batch!
    expect(review_rows.size).to eq(1)

    newer = fs_observe!(app, "SynthLib was uninstalled from SynthApp.")
    DreamStateCompactor.new(run: phase_run).process_batch!
    expect(review_rows.map { |row| row.payload.dig("evidence", "observation_id") }).to eq([ review_rows.first.payload.dig("evidence", "observation_id"), newer.id ])
  end

  it "queues at most three new rows per relation and run" do
    facts = Array.new(4) { |index| fs_observe!(app, "Step #{index}: SynthLib removed.") }

    DreamStateCompactor.new(run: phase_run).process_batch!
    expect(review_rows.map { |row| row.payload.dig("evidence", "observation_id") }).to eq(facts.first(3).map(&:id))

    DreamStateCompactor.new(run: phase_run).process_batch!
    expect(review_rows.size).to eq(4)
  end

  it "resumes the removal pass from its cursor, a batch per job, and pauses between batches" do
    stub_const("DreamStateCompactor::RemovalEvidencePass::BATCH_SIZE", 1)
    other = MemoryEntity.create!(name: "SynthTool", entity_type: "Tool")
    second = MemoryRelation.create!(from_entity: app, to_entity: other, relation_type: "depends_on")
    fs_observe!(app, "SynthApp removed SynthLib and SynthTool.")
    run = phase_run("dependency_pass" => "removal")

    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:continued)
    expect(run.reload.stats).to include("removal_cursor_id" => uses.id, "removal_edges_checked" => 1)
    expect(run.phase).to eq("dependency_edges")

    run.update!(pause_requested: true)
    expect(DreamStateCompactor.new(run: run).process_batch!).to eq(:paused)
    expect(run.reload.stats).to include("removal_cursor_id" => second.id, "removal_edges_checked" => 2, "relation_reviews_queued" => 2)

    run.update!(status: "running")
    DreamStateCompactor.new(run: run).process_batch!
    expect(run.reload.phase).to eq("orphans")
  end
end
