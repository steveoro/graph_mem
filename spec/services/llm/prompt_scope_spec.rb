# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Prompt, "#scoped" do
  it "stores the scope and leaves the rendered text alone" do
    scope = Llm::Scope.for_entities([])
    prompt = described_class.new.trusted("Project: ").data("Gadget Project")

    expect(prompt.scope).to be_nil
    expect(prompt.scoped(scope)).to equal(prompt)
    expect(prompt).to have_attributes(scope: scope, to_s: "Project: Gadget Project")
  end
end
