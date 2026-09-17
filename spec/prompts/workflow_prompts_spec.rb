# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GraphMem workflow prompts" do
  it "defines orient and persist as static prompts" do
    expect(OrientPrompt.metadata).to include(name: "orient")
    expect(OrientPrompt.new.messages.dig(0, :content, :text)).to include("get_context", "set_context")

    expect(PersistPrompt.metadata).to include(name: "persist")
    expect(PersistPrompt.new.messages.dig(0, :content, :text)).to include("graph_write", "possible_duplicate")
  end

  it "defines recall with a required topic" do
    expect(RecallPrompt.metadata[:arguments]).to include(
      name: "topic",
      description: "Keywords or subject to recall",
      required: true
    )
    expect(RecallPrompt.new.messages(topic: "GraphMem").dig(0, :content, :text)).to include(
      "GraphMem",
      "search",
      "get_entities"
    )
  end
end
