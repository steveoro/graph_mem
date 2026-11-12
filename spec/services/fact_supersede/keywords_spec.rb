# frozen_string_literal: true

require "rails_helper"

# 1.78.0: "Outdated by a fact" candidates carry what the keyword paths say, related ones score
# higher, and no unjudged row is proposed for an unrelated pair that no search term found.
RSpec.describe "FactSupersede keyword paths" do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:buffer) { fs_member!(gadget, "FrameBuffer") }
  let!(:alpha) { fs_member!(gadget, "AlphaService") }

  it "boosts a same-subject candidate the fact covers, and keeps the signal (1.82.0)" do
    fact = fs_fact!(widget, "SynthWidget now draws into a FrameBuffer.", tags: [ "replaces:draws" ])
    fs_observe!(widget, "SynthWidget draws straight to the screen, not a FrameBuffer.")
    fs_observe!(widget, "SynthWidget draws for AlphaService.")

    candidates = FactSupersede::Candidates.call(fact).candidates.index_by { |candidate| candidate.observation.content }

    related = candidates.fetch("SynthWidget draws straight to the screen, not a FrameBuffer.")
    # The same subject (SynthWidget, FrameBuffer), no detail: the shared boost (1.78.0 gave the strong one).
    expect(related).to have_attributes(subject: :related, strong: true, shared_keywords: %w[FrameBuffer], level: "same",
                                       score: (FactSupersede::Candidates::TERM_SCORE + FactSupersede::Candidates::POLARITY_BOOST +
                                               FactSupersede::Candidates::SHARED_BOOST).round(3))
    # In memory only: the row's signals reach MCP verbatim.
    expect(related.signals.keys).to contain_exactly("term", "polarity_flip", "scoped")
    other = candidates.fetch("SynthWidget draws for AlphaService.")
    expect(other).to have_attributes(subject: :unrelated, score: FactSupersede::Candidates::TERM_SCORE)
    expect(other.signals).not_to have_key("shared_keywords")
    expect(other.unrelated?).to be(false) # found by a search term
  end

  it "proposes a judged row unless the pair is unrelated and no term found it; an unjudged one only for the same fact (1.82.0)" do
    proposals = FactSupersede::Proposals.new(fs_fact!(widget), terms: [], limit: 10, seed: false, max_batches: nil)
    verdict = ->(subject, term, outcome, same_fact = false) do
      candidate = FactSupersede::Candidate.new(subject: subject, term: term, same_fact: same_fact)
      FactSupersede::Judge::Verdict.new(candidate: candidate, verdict: outcome)
    end

    expect(proposals.send(:proposal?, verdict.call(:unrelated, nil, FactSupersede::Judge::UNJUDGED))).to be(false)
    expect(proposals.send(:proposal?, verdict.call(:unrelated, "draws", FactSupersede::Judge::UNJUDGED))).to be(true)
    expect(proposals.send(:proposal?, verdict.call(:one_sided, nil, FactSupersede::Judge::UNJUDGED))).to be(false)
    expect(proposals.send(:proposal?, verdict.call(:related, nil, FactSupersede::Judge::UNJUDGED))).to be(false)
    expect(proposals.send(:proposal?, verdict.call(:related, nil, FactSupersede::Judge::UNJUDGED, true))).to be(true)
    # Fact keywords off: no subject, as before.
    expect(proposals.send(:proposal?, verdict.call(nil, nil, FactSupersede::Judge::UNJUDGED))).to be(true)
    expect(proposals.send(:proposal?, verdict.call(:related, nil, "superseded"))).to be(true)
    expect(proposals.send(:proposal?, verdict.call(:unrelated, nil, "superseded"))).to be(false)
    expect(proposals.send(:proposal?, verdict.call(:unrelated, "draws", "superseded"))).to be(true)
    expect(proposals.send(:proposal?, verdict.call(:related, nil, "still_valid"))).to be(false)
  end

  it "never sends a sibling pair to the judge, and judges a related one (1.80.0)" do
    rework = fs_member!(gadget, "Rework Plan")
    fact = fs_fact!(rework, "Approve the read-model tools first.").tap { |observation| FactKeywords.compute!([ observation.reload ]) }
    sibling = fs_observe!(widget, "Approve nothing that writes without a review.").tap { |observation| FactKeywords.compute!([ observation.reload ]) }
    related = fs_observe!(rework, "Approve the write tools first.").tap { |observation| FactKeywords.compute!([ observation.reload ]) }
    judged = []
    allow(FactSupersede::Judge).to receive(:call) do |_fact, candidates, **|
      judged.concat(candidates.map(&:observation))
      candidates.map { |candidate| FactSupersede::Judge::Verdict.new(candidate: candidate, verdict: "superseded", confidence: 0.9, judged: true) }
    end
    allow(FactSupersede::Candidates).to receive(:call).and_wrap_original do |method, *args, **options|
      result = method.call(*args, **options)
      # Both found by the vector search, as on a real install where the two texts sit close.
      extra = [ sibling, related ].reject { |observation| result.candidates.any? { |candidate| candidate.observation == observation } }.map do |observation|
        FactSupersede::Candidate.new(observation: observation.reload, score: 0.7, distance: 0.3, scoped: true,
                                     subject: FactKeywords::Relatedness.compare(fact, observation).subject)
      end
      result.with(candidates: result.candidates + extra, vector: true)
    end

    items = FactSupersede::Proposals.call(fact, seed: false).items

    expect(judged).to contain_exactly(related)
    expect(items.map { |item| item["observation_id"] }).to eq([ related.id ])
  end

  it "reads the fact's relations once, not once per sibling candidate, and keeps a joined one" do
    rework = fs_member!(gadget, "Rework Plan")
    joined = fs_member!(gadget, "Rework Notes")
    MemoryRelation.create!(from_entity: joined, to_entity: rework, relation_type: "relates_to")
    fact = fs_fact!(rework, "Approve the read tools first.", tags: [ "replaces:approve" ])
    siblings = [ widget, buffer, alpha ].map { |entity| fs_observe!(entity, "Approve nothing without a review.") }
    near = fs_observe!(joined, "Approve the write tools first.")
    FactKeywords.compute!(MemoryObservation.where(id: [ fact.id, near.id, *siblings.map(&:id) ]).includes(:memory_entity))
    # Relatedness.compare's own check is an exists? query per pair; the preload is two plucks per job.
    pair_queries = 0
    counter = ->(*, payload) { pair_queries += 1 if payload[:sql].match?(/SELECT 1 AS one FROM `memory_relations`/) }

    candidates = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { FactSupersede::Candidates.call(fact).candidates }

    subjects = candidates.to_h { |candidate| [ candidate.observation.id, candidate.subject ] }
    expect(subjects.values_at(*siblings.map(&:id))).to all(eq(:unrelated))
    expect(subjects[near.id]).to eq(:unknown)
    expect(pair_queries).to eq(0)
  end

  it "boosts most a same-subject candidate with a different detail, and none one that covers more than the fact (1.82.0)" do
    fact = fs_fact!(widget, "SynthWidget renders 60 frames into a FrameBuffer.", tags: [ "replaces:FrameBuffer" ])
    fs_observe!(widget, "SynthWidget renders 30 frames into a FrameBuffer.")
    fs_observe!(widget, "SynthWidget renders into a FrameBuffer for AlphaService.")

    candidates = FactSupersede::Candidates.call(fact).candidates.index_by { |candidate| candidate.observation.content }

    detail = candidates.fetch("SynthWidget renders 30 frames into a FrameBuffer.")
    expect(detail).to have_attributes(level: "same", same_fact: true,
                                      score: (FactSupersede::Candidates::TERM_SCORE + FactSupersede::Candidates::STRONG_BOOST).round(3))
    more = candidates.fetch("SynthWidget renders into a FrameBuffer for AlphaService.")
    expect(more).to have_attributes(level: "same", same_fact: false, score: FactSupersede::Candidates::TERM_SCORE)
  end

  it "gives the judge each statement's level and the same-thing rule (1.82.0)" do
    fact = fs_fact!(widget, "SynthWidget renders 60 frames into a FrameBuffer.")
    candidate = FactSupersede::Candidate.new(observation: fs_observe!(widget, "SynthWidget renders 30 frames."), scoped: true, level: "related")

    statement = FactSupersede::Judge.new(fact, nil).send(:statement, candidate)

    expect(statement).to include(subject: "related")
    expect(FactSupersede::Judge::PROMPT_RULES).to include('"superseded" requires the statement to be about the same thing as the fact and to differ in a detail')
  end

  it "sends a candidate whose LLM words share nothing with the fact's to the judge, never skipped (Steve, final review)" do
    fact = fs_fact!(widget, "Deploys with Kamal 2.")
    old = fs_observe!(widget, "Shipped to production via Capistrano.")
    FactKeywords.compute!(MemoryObservation.where(id: [ fact.id, old.id ]).includes(:memory_entity))
    fact.update_columns(llm_keywords: %w[deployment], llm_keywords_at: Time.current)
    old.update_columns(llm_keywords: %w[production release], llm_keywords_at: Time.current)
    candidates = FactSupersede::Candidates.new(fact.reload, query: nil, terms: [], limit: 10, include_inactive: false)
    candidates.instance_variable_set(:@keywords, true)

    candidate = candidates.send(:candidate, old.reload, { old.id => 0.3 }, {})

    expect(candidate.unrelated?).to be(false)
    expect(candidate).to have_attributes(level: "unclear", same_fact: false)
    expect(candidate.seed_unjudged?).to be(false)
  end

  it "leaves candidates as before with fact keywords off" do
    AppSettings.fact_keywords_enabled = false
    fact = fs_fact!(widget, "SynthWidget now draws into a FrameBuffer.", tags: [ "replaces:draws" ])
    fs_observe!(widget, "SynthWidget draws straight to the screen, not a FrameBuffer.")

    candidate = FactSupersede::Candidates.call(fact).candidates.sole

    expect(candidate).to have_attributes(subject: nil, shared_keywords: nil)
    expect(candidate.signals.keys).to contain_exactly("term", "polarity_flip", "scoped")
  ensure
    AppSettings.where(var: "fact_keywords_enabled").delete_all
  end
end
