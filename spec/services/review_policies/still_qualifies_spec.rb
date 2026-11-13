# frozen_string_literal: true

require "rails_helper"

# 1.85.0: the still_qualifies policy dismisses pending compaction suggestions the dream-state
# producers would no longer queue, so a backlog seeded under the looser rules shrinks by itself.
RSpec.describe ReviewPolicies::StillQualifies do
  let(:helper) { DreamStateAcceptanceHelper }

  after { AppSettings.where(var: "enable_review_policy_still_qualifies").delete_all }

  def seed(item)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "dream_state_compaction", items: [ item ]).sole
  end

  def merge_row(entity_a, entity_b, distance:, score:)
    seed({ "kind" => "entity_merge",
           "entity_a" => { "entity_id" => entity_a.id, "name" => entity_a.name, "entity_type" => entity_a.entity_type },
           "entity_b" => { "entity_id" => entity_b.id, "name" => entity_b.name, "entity_type" => entity_b.entity_type },
           "cosine_distance" => distance, "score" => score, "recommendation" => "review_manually" })
  end

  def proposal_row(from, to, relation_type:, score:, terms:, explanation:)
    seed({ "kind" => "relationship_proposal", "from_entity_id" => from.id, "from_name" => from.name,
           "from_entity_type" => from.entity_type, "to_entity_id" => to.id, "to_name" => to.name,
           "to_entity_type" => to.entity_type, "relation_type" => relation_type, "confidence_band" => "high",
           "score" => score, "supporting_observation_ids" => [], "explanation" => explanation, "evidence_terms" => terms })
  end

  def orphan_row(orphan, project, score:, tokens:)
    seed({ "kind" => "orphan_parent", "entity_id" => orphan.id, "entity_name" => orphan.name,
           "entity_type" => orphan.entity_type,
           "suggested_parents" => [ { "project_id" => project.id, "project_name" => project.name, "score" => score,
                                      "matched_tokens" => tokens } ] })
  end

  def task(name, **attrs) = MemoryEntity.create!(name: name, entity_type: "Task", **attrs)

  it "dismisses a merge pair that scored on distance alone and keeps a near-identical pair" do
    far_a = task("Gizmo Tag System")
    far_b = task("Gizmo User Model")
    helper.assign_test_embedding!(far_a, 0.0, 1.0, 0.0)
    helper.assign_test_embedding!(far_b, 0.0, 0.8, 0.6) # cosine distance 0.2, nothing shared
    near_a = task("widget-kit_gem")
    near_b = task("widgetkit_gem")
    helper.assign_test_embedding!(near_a, 1.0, 0.0, 0.0)
    helper.assign_test_embedding!(near_b, 1.0, 0.0, 0.0)

    distance_only = merge_row(far_a, far_b, distance: 0.2, score: 4)
    near = merge_row(near_a, near_b, distance: 0.0, score: 8)

    stats = described_class.new.call

    expect(stats["acted"]).to eq(1)
    expect(distance_only.reload).to have_attributes(status: "dismissed", resolved_by: "policy:still_qualifies",
                                                    resolution_reason: described_class::REASON)
    expect(near.reload.status).to eq("active")
    expect(MaintenanceReportSuppression.count).to eq(0)
  end

  it "leaves Import suggest merges rows (no score) and pairs waiting for an embedding alone" do
    a = task("Sprocket")
    b = task("Flange")
    helper.assign_test_embedding!(a, 0.0, 1.0, 0.0)
    helper.assign_test_embedding!(b, 0.0, 0.8, 0.6)
    imported = seed({ "kind" => "entity_merge", "cosine_distance" => 0.2, "recommendation" => "review_manually",
                      "entity_a" => { "entity_id" => a.id, "name" => a.name, "entity_type" => "Task" },
                      "entity_b" => { "entity_id" => b.id, "name" => b.name, "entity_type" => "Task" } })
    waiting = merge_row(task("Gathering"), task("GatheringEvent"), distance: 0.2, score: 4)

    expect(described_class.new.call["acted"]).to eq(0)
    expect([ imported, waiting ].map { |row| row.reload.status }).to all(eq("active"))
  end

  it "dismisses boilerplate relates_to and 2-term solves proposals, keeps a 3-term solves and depends_on" do
    a = task("PortalHub Route Sessions CRUD Implementation")
    b = task("PortalHub Locale Select Enhancement")
    issue = MemoryEntity.create!(name: "Login flow blocked", entity_type: "Issue")
    fix = MemoryEntity.create!(name: "Login flow fix", entity_type: "PossibleSolution")
    other_issue = MemoryEntity.create!(name: "Session expiry blocked", entity_type: "Issue")

    boilerplate = proposal_row(a, b, relation_type: "relates_to", score: 10, terms: %w[status completed],
                                     explanation: RelationshipDiscoveryStrategy::REMOVED_SHARED_OBSERVATION_EXPLANATION)
    weak_solves = proposal_row(fix, other_issue, relation_type: "solves", score: 11, terms: %w[login flow], explanation: "fix")
    solves = proposal_row(fix, issue, relation_type: "solves", score: 14, terms: %w[login flow blocked], explanation: "fix")
    depends = proposal_row(a, b, relation_type: "depends_on", score: 8, terms: %w[journey], explanation: "uses")

    described_class.new.call

    expect([ boilerplate, weak_solves ].map { |row| row.reload.status }).to all(eq("dismissed"))
    expect([ solves, depends ].map { |row| row.reload.status }).to all(eq("active"))
  end

  it "dismisses an orphan row whose only suggestion has no real evidence, keeps one matched on real tokens" do
    portal_hub = MemoryEntity.create!(name: "PortalHub", entity_type: "Project")
    relay = MemoryEntity.create!(name: "relay_admin2", entity_type: "Project")
    bonus_only = orphan_row(task("Stage 1 Test Coverage"), portal_hub, score: 2, tokens: [])
    real = orphan_row(task("Patch Test Runner Script", description: "relay admin2 script"), relay,
                      score: 20, tokens: %w[relay admin2])

    described_class.new.call

    expect(bonus_only.reload.status).to eq("dismissed")
    expect(real.reload.status).to eq("active")
  end

  it "leaves rows whose entities are gone to the Dangling policy" do
    orphan = task("Stage 1 Test Coverage")
    row = orphan_row(orphan, MemoryEntity.create!(name: "PortalHub", entity_type: "Project"), score: 2, tokens: [])
    orphan.destroy!

    expect(described_class.new.call["acted"]).to eq(0)
    expect(row.reload.status).to eq("active")
  end

  it "counts what it would dismiss, read-only, through review:still_qualifies_report (Graphy, #172)" do
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("review:still_qualifies_report")
    portal = MemoryEntity.create!(name: "PortalHub", entity_type: "Project")
    below = orphan_row(task("Stage 1 Test Coverage"), portal, score: 2, tokens: [])

    expect(described_class.preview["orphan_parent"]).to eq("pending" => 1, "below_bar" => 1)
    expect { Rake::Task["review:still_qualifies_report"].invoke }
      .to output(/orphan_parent: 1 pending; 1 below the current evidence bar/).to_stdout
    expect(below.reload.status).to eq("active")
  ensure
    Rake::Task["review:still_qualifies_report"].reenable
  end

  it "runs with the other policies and can be turned off" do
    row = orphan_row(task("Stage 1 Test Coverage"), MemoryEntity.create!(name: "PortalHub", entity_type: "Project"),
                     score: 2, tokens: [])
    AppSettings.enable_review_policy_still_qualifies = false

    expect(ReviewPolicyRunner.call(trigger: "spec").dig("policies", "still_qualifies")).to include("disabled" => true)
    expect(row.reload.status).to eq("active")
  end
end
