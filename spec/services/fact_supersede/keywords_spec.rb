# frozen_string_literal: true

require "rails_helper"

# 1.78.0: "Outdated by a fact" candidates carry what the keyword paths say, related ones score
# higher, and no unjudged row is proposed for an unrelated pair that no search term found.
RSpec.describe "FactSupersede keyword paths" do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:buffer) { fs_member!(gadget, "FrameBuffer") }
  let!(:alpha) { fs_member!(gadget, "AlphaService") }

  it "boosts a related candidate, most for a shared first mention, and keeps the signal" do
    fact = fs_fact!(widget, "SynthWidget now draws into a FrameBuffer.", tags: [ "replaces:draws" ])
    fs_observe!(widget, "SynthWidget draws straight to the screen, not a FrameBuffer.")
    fs_observe!(widget, "SynthWidget draws for AlphaService.")

    candidates = FactSupersede::Candidates.call(fact).candidates.index_by { |candidate| candidate.observation.content }

    related = candidates.fetch("SynthWidget draws straight to the screen, not a FrameBuffer.")
    expect(related).to have_attributes(subject: :related, strong: true, shared_keywords: %w[FrameBuffer],
                                       score: (FactSupersede::Candidates::TERM_SCORE + FactSupersede::Candidates::POLARITY_BOOST +
                                               FactSupersede::Candidates::STRONG_BOOST).round(3))
    # In memory only: the row's signals reach MCP verbatim.
    expect(related.signals.keys).to contain_exactly("term", "polarity_flip", "scoped")
    other = candidates.fetch("SynthWidget draws for AlphaService.")
    expect(other).to have_attributes(subject: :unrelated, score: FactSupersede::Candidates::TERM_SCORE)
    expect(other.signals).not_to have_key("shared_keywords")
    expect(other.unrelated?).to be(false) # found by a search term
  end

  it "proposes an unjudged row unless the pair is unrelated and no term found it" do
    proposals = FactSupersede::Proposals.new(fs_fact!(widget), terms: [], limit: 10, seed: false, max_batches: nil)
    verdict = ->(subject, term, outcome) do
      FactSupersede::Judge::Verdict.new(candidate: FactSupersede::Candidate.new(subject: subject, term: term), verdict: outcome)
    end

    expect(proposals.send(:proposal?, verdict.call(:unrelated, nil, FactSupersede::Judge::UNJUDGED))).to be(false)
    expect(proposals.send(:proposal?, verdict.call(:unrelated, "draws", FactSupersede::Judge::UNJUDGED))).to be(true)
    expect(proposals.send(:proposal?, verdict.call(:one_sided, nil, FactSupersede::Judge::UNJUDGED))).to be(true)
    expect(proposals.send(:proposal?, verdict.call(nil, nil, FactSupersede::Judge::UNJUDGED))).to be(true)
    expect(proposals.send(:proposal?, verdict.call(:unrelated, nil, "superseded"))).to be(true)
    expect(proposals.send(:proposal?, verdict.call(:related, nil, "still_valid"))).to be(false)
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
