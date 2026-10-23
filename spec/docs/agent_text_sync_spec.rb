# frozen_string_literal: true

require "rails_helper"

# One rule file for every agent (root AGENTS.md), skills discovered through
# links to the canonical skills/ folders, and every SKILL.md held to the Agent
# Skills validator rules (mirrored from skills-ref, which is not run in CI).
RSpec.describe "agent text sync" do
  let(:root) { Rails.root }
  let(:agents_md) { root.join("AGENTS.md").read }
  let(:snippet) { root.join("docs/rules/graph_mem_mcp_rules.md").read }
  let(:skill_names) { %w[graph-mem-mcp-toolset project-scan] }
  let(:spec_fields) { %w[name description license compatibility metadata allowed-tools] }
  let(:vendor_extras) { { "project-scan" => %w[triggers disable-model-invocation] } }

  # Splits like skills-ref's parser: the text between the first two "---".
  def frontmatter_block(path)
    content = File.read(path)
    raise "#{path} must start with ---" unless content.start_with?("---\n")

    content.split("---", 3)[1]
  end

  def frontmatter(path)
    YAML.safe_load(frontmatter_block(path))
  end

  def body(path)
    File.read(path).split("---", 3)[2]
  end

  def skill_files
    %w[skills .agents/skills .claude/skills].flat_map { |dir| root.glob("#{dir}/*/SKILL.md") }
  end

  describe "one rule file" do
    it "embeds the copy-out snippet verbatim as the AGENTS.md graph_mem section" do
      expect(snippet).to start_with("## graph_mem memory (MCP)\n")
      expect(snippet).not_to start_with("---")
      expect(snippet.lines.size).to be <= 12
      expect(agents_md).to include(snippet)
    end

    it "carries the general coding rules in AGENTS.md" do
      coding_rules = root.join("docs/rules/general_coding_rules.md").read
      bullets = coding_rules[coding_rules.index("- **Schema first**")..]

      expect(coding_rules).not_to start_with("---")
      expect(agents_md).to include(bullets)
    end

    it "makes CLAUDE.md import AGENTS.md without repeating it" do
      lines = root.join("CLAUDE.md").read.lines.map(&:chomp)
      rest = lines.drop(1).reject { |line| line.strip.empty? || line.start_with?("#") }

      expect(lines.first).to eq("@AGENTS.md")
      expect(rest.select { |line| agents_md.include?(line) }).to be_empty
      expect(lines.drop(1).reject { |line| line.strip.empty? }.first).to(eq("## Claude Code only")) if rest.any?
    end
  end

  describe "no per-tool rule files" do
    it "has no Cursor or Devin rules folders" do
      expect(root.join(".cursor/rules")).not_to exist
      expect(root.join(".devin/rules")).not_to exist
    end

    it "tracks no other per-tool rule files" do
      tracked = `git -C #{root} ls-files -- .cursorrules .windsurfrules .github/copilot-instructions.md .claude/rules`

      expect(tracked).to be_empty
    end
  end

  describe "reference text only in the skill" do
    it "keeps docs/rules to the copy-out snippets and the README" do
      expect(root.glob("docs/rules/*").map { |path| path.basename.to_s })
        .to contain_exactly("README.md", "graph_mem_mcp_rules.md", "general_coding_rules.md")
    end

    it "links the tool reference from SKILL.md" do
      expect(root.join("skills/graph-mem-mcp-toolset/references/tools.md")).to exist
      expect(root.join("skills/graph-mem-mcp-toolset/SKILL.md").read).to include("Read `references/tools.md` when")
    end
  end

  describe "skill discovery" do
    it "links each skill from .agents/skills and .claude/skills" do
      skill_names.each do |name|
        %w[.agents/skills .claude/skills].each do |dir|
          link = root.join(dir, name)

          expect(link).to be_symlink, "#{link} is not a symlink"
          expect(link.realpath).to eq(root.join("skills", name).realpath)
        end
      end
    end

    it "has no retired skill locations" do
      %w[.cursor/skills .devin .windsurf].each { |path| expect(root.join(path)).not_to exist }
    end

    it "runs project-scan only on request" do
      fields = frontmatter(root.join("skills/project-scan/SKILL.md"))

      expect(fields).to include("disable-model-invocation" => true, "triggers" => [ "user" ])
    end
  end

  describe "Agent Skills validator rules" do
    it "finds every SKILL.md" do
      expect(skill_files.size).to eq(skill_names.size * 3)
    end

    it "keeps frontmatter to block-style YAML with valid fields" do
      skill_files.each do |path|
        block = frontmatter_block(path)
        fields = frontmatter(path)
        expect(fields).to be_a(Hash), "#{path}: frontmatter must be a YAML mapping"
        name = fields["name"]

        expect(block).not_to match(/:\s*[\[{]/), "#{path}: flow-style collection in frontmatter"
        expect(name).to match(/\A[a-z0-9]+(-[a-z0-9]+)*\z/).and(satisfy { name.length.between?(1, 64) })
        expect(name).to eq(path.dirname.basename.to_s)
        expect(fields["description"]).to be_a(String).and(be_present)
        expect(fields["description"].length).to be <= 1024
        expect(fields.keys - spec_fields - vendor_extras.fetch(name, [])).to be_empty, "#{path}: unexpected fields"
        expect(fields["compatibility"].to_s.length).to be <= 500
        if fields.key?("metadata")
          expect(fields["metadata"]).to be_a(Hash)
          expect(fields["metadata"].to_a.flatten).to all(be_a(String))
        end
      end
    end

    it "keeps bodies short and links only to files inside the skill" do
      skill_files.each do |path|
        skill_root = path.dirname
        text = body(path)
        links = text.scan(/\]\(([^)#]+)\)/).flatten + text.scan(/`(references\/[^`]+)`/).flatten

        expect(text.lines.size).to be < 500
        links.reject { |link| link.match?(%r{\A[a-z]+://}) }.each do |link|
          expect(link.count("/")).to be <= 1, "#{path}: #{link} is nested too deep"
          expect(skill_root.join(link)).to exist, "#{path}: #{link} does not exist"
        end
        skill_root.glob("references/*").each do |reference|
          expect(text).to include("Read `references/#{reference.basename}` when")
        end
      end
    end

    it "ships no scripts and no URLs" do
      skill_names.each do |name|
        skill_root = root.join("skills", name)

        expect(skill_root.join("scripts")).not_to exist
        skill_root.glob("**/*").select(&:file?).each do |file|
          expect(file.read).not_to match(%r{https?://}), "#{file} contains a URL"
        end
      end
    end
  end
end
