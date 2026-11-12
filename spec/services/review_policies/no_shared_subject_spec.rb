# frozen_string_literal: true

require "rails_helper"
require "rake"

# 1.78.0: the no_shared_subject policy dismisses pending pair rows whose facts share no subject by
# their keyword paths, with the generators' own rules; the read-only report counts them first.
RSpec.describe ReviewPolicies::NoSharedSubject do
  let!(:root) { fs_project!("Gadget Project") }
  let!(:grant) { fs_member!(root, "AdminGrant", "Model") }

  before do
    fs_member!(root, "User", "Model")
    fs_member!(root, "Team", "Model")
  end

  after { AppSettings.where(var: %w[fact_keywords_enabled enable_review_policy_no_shared_subject]).delete_all }

  def computed(content, entity = grant)
    fs_observe!(entity, content).tap { |observation| FactKeywords.compute!([ observation.reload ]) }
  end

  def contradiction_row(first, second, distance: 0.1)
    item = ContradictionDetector.review_item(ContradictionDetector::Result.new(observation_id_1: first.id, observation_id_2: second.id,
                                                                                distance: distance, confidence: 0.9))
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "stale_memory_scan", items: [ item ]).sole
  end

  def supersede_row(fact, observation, verdict: FactSupersede::Judge::UNJUDGED, term: nil)
    item = { "kind" => "fact_supersede", "fact_observation_id" => fact.id, "observation_id" => observation.id, "verdict" => verdict,
             "confidence" => 0.5, "signals" => { "term" => term, "scoped" => true }.compact, "content" => observation.content,
             "fact_content" => fact.content, "entity_id" => observation.memory_entity_id, "entity_name" => "AdminGrant" }
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "fact_supersede", source_ref: "fact:#{fact.id}",
                                        items: [ item ]).sole
  end

  it "dismisses unrelated contradiction rows and keeps related ones, with the run's reason" do
    unrelated = contradiction_row(computed("It belongs to a User."), computed("It is not linked to a Team."))
    related = contradiction_row(computed("It names a User."), computed("It does not name a User."))

    stats = described_class.new.call

    expect(stats["acted"]).to eq(1)
    expect(unrelated.reload).to have_attributes(status: "dismissed", resolution_reason: ReviewPolicies::SubjectCheck::REASON)
    expect(related.reload.status).to eq("active")
  end

  it "leaves rows with a pending path and term matches alone; dismisses unrelated rows, judged or not (1.80.0)" do
    pending = contradiction_row(fs_observe!(grant, "It belongs to a User."), computed("It is not linked to a Team."))
    fact = fs_fact!(grant, "AdminGrant now belongs to a Team.").tap { |observation| FactKeywords.compute!([ observation.reload ]) }
    target = computed("It belongs to a User.")
    judged = supersede_row(fact, target, verdict: "superseded")
    by_term = supersede_row(fact, computed("It still points at a User."), term: "belongs")
    unjudged = supersede_row(fact, computed("It belongs to one User."))

    described_class.new.call

    expect([ pending, by_term ].map { |row| row.reload.status }).to all(eq("active"))
    expect([ judged, unjudged ].map { |row| row.reload.status }).to all(eq("dismissed"))
  end

  it "dismisses rows pairing facts on two sibling entities, and keeps a fact held by the project root (1.80.0)" do
    rework = fs_member!(root, "Rework Plan")
    rules = fs_member!(root, "Server Rules")
    fact = fs_fact!(rework, "Approve the read-model tools first.").tap { |observation| FactKeywords.compute!([ observation.reload ]) }
    sibling_row = supersede_row(fact, computed("Never pass the development database to the analyzer.", rules), verdict: "superseded")
    contradiction = contradiction_row(computed("Approve the reads first.", rework), computed("Do not approve reads before writes.", rules))
    root_row = supersede_row(fact, computed("Never approve a tool without a test.", root), verdict: "superseded")

    described_class.new.call

    expect([ sibling_row, contradiction ].map { |row| row.reload.status }).to all(eq("dismissed"))
    expect(root_row.reload.status).to eq("active")
  end

  it "mirrors the 1.82.0 seeding: an unjudged row needs the same fact with a different detail; a judged related row stays" do
    fs_member!(root, "Season", "Model")
    fact = fs_fact!(grant, "AdminGrant allows 5 Users per Team.").tap { |observation| FactKeywords.compute!([ observation.reload ]) }
    related = computed("It links a Team to a Season.")
    detail = computed("It allows 3 Users per Team.")

    unjudged_related = supersede_row(fact, related)
    unjudged_detail = supersede_row(fact, detail)
    judged_related = supersede_row(fact, computed("It ties a Team to one Season."), verdict: "superseded")

    described_class.new.call

    expect(unjudged_related.reload).to have_attributes(status: "dismissed", resolution_reason: ReviewPolicies::SubjectCheck::REASON_NOT_SAME)
    expect([ unjudged_detail, judged_related ].map { |row| row.reload.status }).to all(eq("active"))
  end

  it "does nothing with fact keywords off or its own toggle off" do
    row = contradiction_row(computed("It belongs to a User."), computed("It is not linked to a Team."))

    AppSettings.fact_keywords_enabled = false
    expect(described_class.new.call).to include("disabled" => true)
    AppSettings.fact_keywords_enabled = true
    AppSettings.enable_review_policy_no_shared_subject = false
    expect(described_class.new.call).to include("disabled" => true)
    expect(row.reload.status).to eq("active")
  end

  it "runs in the nightly review policy run" do
    contradiction_row(computed("It belongs to a User."), computed("It is not linked to a Team."))

    expect(ReviewPolicyRunner.call(trigger: "spec").dig("policies", "no_shared_subject", "acted")).to eq(1)
  end

  it "is counted by the read-only report task first" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("graph_mem:fact_keywords:review_report")
    row = contradiction_row(computed("It belongs to a User."), computed("It is not linked to a Team."))

    expect { Rake::Task["graph_mem:fact_keywords:review_report"].invoke }
      .to output(/contradiction: 1 pending; 1 would be dismissed \(1 share no subject, 0 not the same fact\)/).to_stdout
    expect(row.reload.status).to eq("active")
  ensure
    Rake::Task["graph_mem:fact_keywords:review_report"].reenable
  end
end
