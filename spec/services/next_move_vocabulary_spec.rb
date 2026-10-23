# frozen_string_literal: true

require "rails_helper"

# Agent-facing hints must name only operations the MCP mutation tools accept.
module NextMoveVocabularySpec
  SERVICE_FILES = Rails.root.glob("app/services/graph_{write,edit,delete}_service.rb").freeze
  RELATION_SEMANTICS_FILE = Rails.root.join("app/services/relation_semantics.rb")
  TOOL_TYPES = {
    "graph_write" => GraphWriteService::TYPES,
    "graph_edit" => GraphEditService::TYPES,
    "graph_delete" => GraphDeleteService::TYPES
  }.freeze
  STRING_LITERAL = /"((?:[^"\\]|\\.)*)"/
  # `graph_edit` update_entity / graph_delete delete_relation (an op is snake_case).
  OPERATION_MENTION = /`?\b(graph_(?:write|edit|delete))\b`?\s+([a-z]+_[a-z_]+)/
end

RSpec.describe "next_move vocabulary" do
  def hint_strings
    from_services = NextMoveVocabularySpec::SERVICE_FILES.flat_map do |path|
      File.read(path).scan(/next_move:\s*#{NextMoveVocabularySpec::STRING_LITERAL}/o).flatten
    end
    # relation_semantics raises validation messages (no next_move), which MCP
    # returns verbatim, so every literal in it counts as a hint.
    from_services + File.read(NextMoveVocabularySpec::RELATION_SEMANTICS_FILE).scan(NextMoveVocabularySpec::STRING_LITERAL).flatten
  end

  it "collects the hints it checks" do
    expect(hint_strings.size).to be > 10
  end

  it "names only operations listed in the mutation service's TYPES" do
    mentions = hint_strings.flat_map { |hint| hint.scan(NextMoveVocabularySpec::OPERATION_MENTION) }
    expect(mentions).not_to be_empty

    unknown = mentions.reject { |tool, op| NextMoveVocabularySpec::TOOL_TYPES.fetch(tool).include?(op) }
    expect(unknown).to be_empty, "unknown operations in hints: #{unknown.inspect}"
  end

  it "never points at move_to_parent, which MCP does not expose" do
    (NextMoveVocabularySpec::SERVICE_FILES + [ NextMoveVocabularySpec::RELATION_SEMANTICS_FILE ]).each do |path|
      expect(File.read(path)).not_to include("move_to_parent"), "#{path} mentions move_to_parent"
    end
  end
end
