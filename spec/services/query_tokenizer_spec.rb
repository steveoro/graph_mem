# frozen_string_literal: true

require "rails_helper"

RSpec.describe QueryTokenizer do
  it "normalizes punctuation and removes stopwords" do
    tokens = described_class.tokenize("Graph-Mem: the summarization tool")
    expect(tokens).to include("graph", "mem", "summarization", "tool")
    expect(tokens).not_to include("the")
  end

  it "scores token overlap" do
    score = described_class.overlap_score(%w[graph mem], "Graph Mem project notes")
    expect(score).to eq(1.0)
  end
end
