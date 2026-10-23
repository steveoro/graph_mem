# frozen_string_literal: true

require "rails_helper"

# Agent-facing text is situation-first and names only tools the reader can
# actually call on the connection that shows it.
RSpec.describe "agent-facing text" do
  let(:registry) { GraphMem::McpToolRegistry }
  let(:all_tools) { registry.tool_classes }
  let(:tool_names) { all_tools.map(&:tool_name) }
  # Operation types double as hidden alias tool names (create_entity, ...);
  # in agent text they name `operations` items, so they are not tool mentions.
  let(:operation_types) { GraphWriteService::TYPES + GraphEditService::TYPES + GraphDeleteService::TYPES }
  let(:hidden_aliases) { all_tools.reject(&:mcp_advertised?).map(&:tool_name) - operation_types }
  let(:maintenance_only) do
    registry.tool_classes_for(:maintenance).map(&:tool_name) - registry.tool_classes_for(:default).map(&:tool_name)
  end

  before { registry.load_all! }

  def advertised_on(profile)
    registry.tool_classes_for(profile).select(&:mcp_advertised?).map(&:tool_name)
  end

  # Tool names mentioned in a text, ignoring operation types.
  def named_tools(text)
    pattern = /\b(#{(tool_names - operation_types).sort_by { -_1.length }.join('|')})\b/
    text.scan(pattern).flatten.uniq
  end

  # Drops "Do not use X; use `y` instead." routing sentences: they point away
  # from the wrong tool and may name one that lives on another profile.
  def without_routing(text)
    text.gsub(/Do not [^.]*\./, "")
  end

  # Paragraphs that do not point the reader at the maintenance connection.
  def non_maintenance_paragraphs(text)
    text.split(/\n\s*\n/).reject { |paragraph| paragraph.match?(%r{/mcp/maintenance|maintenance profile}i) }
  end

  def expect_only_tools_on(text, profiles, label)
    # The skill's Gotchas warn against the hidden aliases by name; that line is exempt.
    text = text.gsub(/^.*Hidden aliases.*$/, "")
    allowed = Array(profiles).map { |profile| advertised_on(profile) }.reduce(:&)
    unknown = named_tools(without_routing(text)) - allowed
    expect(unknown).to be_empty, "#{label} names tools not on #{Array(profiles).join('/')}: #{unknown.inspect}"
    hits = hidden_aliases.select { |name| text.match?(/\b#{name}\b/) }
    expect(hits).to be_empty, "#{label} names hidden aliases: #{hits.inspect}"
  end

  describe "tool description openers" do
    it "starts the main tools with their trigger sentence" do
      expect(SearchTool.description).to start_with("Recall what earlier sessions learned")
      expect(GraphWriteTool.description).to start_with("Persist a durable lesson")
      expect(GraphEditTool.description).to start_with("Rewrite what the graph already knows")
    end
  end

  it "names only reachable tools in advertised tool descriptions" do
    all_tools.select(&:mcp_advertised?).each do |tool|
      expect_only_tools_on(tool.description.to_s, tool.mcp_profiles, "#{tool.tool_name} description")
    end
  end

  it "names only reachable tools in prompt descriptions and texts" do
    registry.prompt_classes.each do |prompt|
      instance = prompt.new
      messages = prompt == RecallPrompt ? instance.messages(topic: "SynthWidget") : instance.messages
      text = [ prompt.metadata[:description], messages.dig(0, :content, :text) ].join("\n")
      expect_only_tools_on(text, prompt.mcp_profiles, "#{prompt.metadata[:name]} prompt")
    end
  end

  it "names only reachable tools in next_move hints" do
    ToolSuccessResponse::DEFAULT_HINTS.each do |tool_name, hint|
      tool = all_tools.find { |klass| klass.tool_name == tool_name }
      expect_only_tools_on(hint, tool.mcp_profiles, "#{tool_name} next_move")
    end
    %w[get_context set_context].each do |tool_name|
      tool = all_tools.find { |klass| klass.tool_name == tool_name }
      [ { status: "no_context" }, { status: "active" }, { status: "context_cleared" } ].each do |payload|
        hint = ToolSuccessResponse.send(:next_move_for, tool_name, payload)
        expect_only_tools_on(hint, tool.mcp_profiles, "#{tool_name} next_move")
      end
    end
  end

  it "names only reachable tools in the server instructions" do
    GraphMem::McpProfile::NAMES.each do |profile|
      expect_only_tools_on(GraphMem::McpInstructions.for(profile), profile, "#{profile} instructions")
    end
  end

  it "keeps maintenance tools out of the AGENTS.md section and the skill, except next to /mcp/maintenance" do
    # references/maintenance.md is the one place maintenance tools are described freely.
    [ "docs/rules/graph_mem_mcp_rules.md", "skills/graph-mem-mcp-toolset/SKILL.md" ].each do |path|
      text = Rails.root.join(path).read
      expect_only_tools_on(text, :maintenance, path)
      expect_only_tools_on(non_maintenance_paragraphs(text).join("\n\n"), :default, path)
      expect(named_tools(text) & maintenance_only).to all(satisfy { |name|
        text.split(/\n\s*\n/).any? { |paragraph| paragraph.include?(name) && paragraph.include?("/mcp/maintenance") }
      })
    end
  end
end
