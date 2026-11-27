# frozen_string_literal: true

require "rails_helper"

# 1.96.1 (review guidance, item 4): SKILL.md's "Persist" section and the `persist` prompt carry the
# same placement rules, so the two texts can't drift: source facts on the entity the changed
# statement is about, the Project entity only for whole-project statements, other facts on the most
# specific entity, and a shallow hierarchy.
RSpec.describe "fact placement in SKILL.md and the persist prompt" do
  # Both texts, with line wraps and Markdown code marks folded away.
  let(:skill) do
    text = Rails.root.join("skills/graph-mem-mcp-toolset/SKILL.md").read
    text[/^## Persist: before your final reply\n.*?(?=^## )/m].delete("`").squish
  end
  let(:prompt) { PersistPrompt.new.messages.dig(0, :content, :text).delete("`").squish }

  [
    "Use the Project entity only for a statement about the whole project.",
    "Put every other fact on the most specific existing entity it is about, not on the Project entity.",
    "on the entity the changed statement is about",
    "Search for it, and create it part_of the Project if it doesn't exist.",
    "Project → Component or Feature → Task or Issue, three levels at most",
    "PossibleSolution that solves it",
    "Search before you create any entity",
    "source-fact"
  ].each do |rule|
    it "carries \"#{rule.truncate(60)}\" in both" do
      expect(skill).to include(rule)
      expect(prompt).to include(rule)
    end
  end

  it "no longer puts source facts on the project's entity" do
    expect(skill).not_to include("on the project's entity")
    expect(prompt).not_to include("on the project's entity")
  end
end
