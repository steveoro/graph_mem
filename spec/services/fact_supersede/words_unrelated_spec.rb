# frozen_string_literal: true

require "rails_helper"
require "rake"

# 1.96.1 (review guidance, item 3; Steve, 2026-11-27: any one entity): two facts on one entity that
# mention no entity and share no LLM word ("words-unrelated") are skipped like a pair the keyword
# paths call unrelated. The generator neither judges nor proposes such a pair, unless a search term
# found it, and the no_shared_subject policy dismisses its row, judged or not, with its own reason.
# Words-related pairs and contradiction rows are unchanged.
RSpec.describe "FactSupersede › words-unrelated pairs", :with_test_embeddings do
  let!(:project) { fs_project!("SynthApp") }
  let(:axis) { ->(index) { Array.new(768, 0.0).tap { |vector| vector[index] = 1.0 } } }
  let(:judged) { [] }
  # The plan's Context row, in synthetic form: a source fact from a doc and an agent's fact about a
  # test-driver fix, both on the Project root, both naming no entity, their LLM words apart.
  let(:fact) { words(fs_fact!(project, "Entity deletes take the membership lock first.", tags: tags), %w[membership locking]) }
  let(:tags) { [] }
  let(:driver_fix) { words(fs_observe!(project, "The test driver fix waits for the page to settle."), %w[test driver]) }

  before do
    # Every text sits close to the fact, as the vector search finds such pairs on a real install.
    allow(EmbeddingService.instance).to receive(:embed).and_return(axis.call(0))
    allow(FactSupersede::Judge).to receive(:call) do |_fact, candidates, **|
      judged.concat(candidates.map(&:observation))
      candidates.map do |candidate|
        FactSupersede::Judge::Verdict.new(candidate: candidate, verdict: "superseded", confidence: 0.7, judged: true,
                                          reason: "synthetic", replacement: "Entity deletes take the membership lock first.")
      end
    end
  end

  after { AppSettings.where(var: %w[fact_keywords_enabled enable_review_policy_no_shared_subject]).delete_all }

  # Computes the keyword path, then stores the LLM words (no LLM call).
  def words(observation, llm_words)
    FactKeywords.compute!([ observation.reload ])
    observation.update_columns(llm_keywords: llm_words, llm_keywords_at: Time.current)
    observation.reload
  end

  def supersede_row(observation, verdict:, term: nil)
    item = { "kind" => "fact_supersede", "fact_observation_id" => fact.id, "observation_id" => observation.id, "verdict" => verdict,
             "confidence" => 0.7, "signals" => { "term" => term, "scoped" => true }.compact, "content" => observation.content,
             "fact_content" => fact.content, "entity_id" => observation.memory_entity_id, "entity_name" => project.name }
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "fact_supersede", source_ref: "fact:#{fact.id}",
                                        items: [ item ]).sole
  end

  it "names the pair words-unrelated, not unrelated by the keyword paths" do
    comparison = FactKeywords::Relatedness.compare(fact, driver_fix)

    expect(comparison).to have_attributes(subject: :unrelated, by_words: true, words_unrelated?: true, hard_unrelated?: false)
  end

  it "neither judges nor proposes the Context row's pair" do
    driver_fix

    result = FactSupersede::Proposals.call(fact)

    expect(result.candidates).to eq(1)
    expect(judged).to be_empty
    expect(result.items).to be_empty
    expect(MaintenanceReportRow.where(kind: "fact_supersede")).not_to exist
  end

  it "skips it on any one entity, a member's too" do
    member = fs_member!(project, "SynthApp Conventions", "BestPractice")
    rule = words(fs_observe!(member, "The test driver fix waits for the page to settle."), %w[test driver])
    other = words(fs_fact!(member, "Deletes take the membership lock first."), %w[membership locking])

    expect(FactSupersede::Proposals.call(other).items).to be_empty
    expect(judged).to be_empty
    expect(FactKeywords::Relatedness.compare(other, rule).words_unrelated?).to be(true)
  end

  it "still judges and proposes a words-related pair" do
    related = words(fs_observe!(project, "The deletes wait for the membership lock."), %w[membership deletion])

    items = FactSupersede::Proposals.call(fact).items

    expect(judged).to eq([ related ])
    expect(items.map { |item| item["observation_id"] }).to eq([ related.id ])
  end

  context "with a search term that matches it" do
    let(:tags) { [ "replaces:test driver" ] }

    it "judges and proposes the pair as before" do
      driver_fix

      items = FactSupersede::Proposals.call(fact).items

      expect(judged).to eq([ driver_fix ])
      expect(items.sole).to include("observation_id" => driver_fix.id, "verdict" => "superseded", "signals" => include("term" => "test driver"))
    end
  end

  describe "the no_shared_subject policy" do
    it "dismisses a pending row of that shape, judged or not, with its own reason, and leaves a term match" do
      judged_row = supersede_row(driver_fix, verdict: "superseded")
      unjudged_row = supersede_row(words(fs_observe!(project, "The test driver retries a click once."), %w[click retry]),
                                   verdict: FactSupersede::Judge::UNJUDGED)
      by_term = supersede_row(words(fs_observe!(project, "The test driver scrolls first."), %w[scrolling]), verdict: "superseded",
                                                                                                             term: "test driver")

      expect(ReviewPolicies::SubjectCheck.status(judged_row)).to eq(:dismiss)
      ReviewPolicies::NoSharedSubject.new.call

      expect([ judged_row, unjudged_row ].map(&:reload))
        .to all(have_attributes(status: "dismissed", resolution_reason: ReviewPolicies::SubjectCheck::REASON_NO_SHARED_WORD))
      expect(by_term.reload.status).to eq("active")
    end
  end

  describe "the read-only review report" do
    it "counts such rows apart" do
      Rails.application.load_tasks unless Rake::Task.task_defined?("graph_mem:fact_keywords:review_report")
      supersede_row(driver_fix, verdict: "superseded")

      expect { Rake::Task["graph_mem:fact_keywords:review_report"].invoke }
        .to output(/fact_supersede: 1 pending; 1 would be dismissed \(0 share no subject, 1 share no LLM word, 0 not the same fact/).to_stdout
    ensure
      Rake::Task["graph_mem:fact_keywords:review_report"].reenable
    end
  end

  describe "contradiction rows of that shape" do
    def contradiction_row(first, second)
      result = ContradictionDetector::Result.new(observation_id_1: first.id, observation_id_2: second.id, distance: 0.1, confidence: 0.9)
      CompactionReviewService.seed_report(report_type: "compaction_review", source: "stale_memory_scan",
                                          items: [ ContradictionDetector.review_item(result) ]).sole
    end

    it "keeps the contradiction rules and reasons" do
      value_change = contradiction_row(words(fs_observe!(project, "Port: 3000"), %w[port]), words(fs_observe!(project, "Port: 3001"), %w[server]))
      polarity = contradiction_row(words(fs_observe!(project, "Deploys run on Fridays."), %w[deploys]),
                                   words(fs_observe!(project, "Backups never run on Mondays."), %w[backups]))

      expect(ReviewPolicies::SubjectCheck.status(value_change)).to eq(:keep)
      expect(ReviewPolicies::SubjectCheck.reason(polarity)).to eq(ReviewPolicies::SubjectCheck::REASON_NOT_CONTRADICTION)
      ReviewPolicies::NoSharedSubject.new.call
      expect(value_change.reload.status).to eq("active")
      expect(polarity.reload).to have_attributes(status: "dismissed", resolution_reason: ReviewPolicies::SubjectCheck::REASON_NOT_CONTRADICTION)
    end
  end
end
