# frozen_string_literal: true

require "rails_helper"

# Skills over MCP (1.91.0): which skills each profile serves, and the catalog rebuilt per call.
RSpec.describe GraphMem::McpSkills do
  def write_skill(root, name, body)
    FileUtils.mkdir_p(File.join(root, name))
    File.write(File.join(root, name, "SKILL.md"), "---\nname: #{name}\ndescription: A synthetic skill for specs.\n---\n\n#{body}\n")
  end

  it "serves the toolset skill on every profile, and project-scan off readonly" do
    names = GraphMem::McpProfile::NAMES.index_with { |profile| described_class.for(profile).map(&:name) }

    expect(names).to eq(default: %w[graph-mem-mcp-toolset project-scan], readonly: %w[graph-mem-mcp-toolset],
                        maintenance: %w[graph-mem-mcp-toolset project-scan])
    expect(described_class.for("readonly").first.resources.map { |entry| entry.uri.delete_prefix("skill://graph-mem-mcp-toolset/") })
      .to contain_exactly("SKILL.md", "references/hosts.md", "references/maintenance.md", "references/tools.md")
  end

  it "decides every skill in skills/ in PROFILES, for known profiles only" do
    on_disk = Rails.root.join("skills").children.select { |dir| dir.join("SKILL.md").file? }.map { |dir| dir.basename.to_s }

    expect(described_class::PROFILES.keys).to match_array(on_disk)
    expect(described_class::PROFILES.values.flatten.uniq - GraphMem::McpProfile::NAMES).to be_empty
  end

  it "reads the skills again on every call, so an edited file is served with its new digest" do
    Dir.mktmpdir("mcp-skills") do |root|
      stub_const("#{described_class}::PROFILES", { "synth-alpha" => %i[default], "synth-beta" => %i[maintenance] })
      write_skill(root, "synth-alpha", "First text.")
      write_skill(root, "synth-beta", "Maintenance only.")
      first = described_class.for(:default, root: root)
      write_skill(root, "synth-alpha", "Second, longer text.")
      second = described_class.for(:default, root: root)

      expect([ first, second ].map { |skills| skills.map(&:name) }).to eq([ %w[synth-alpha], %w[synth-alpha] ])
      expect(first.first).not_to equal(second.first)
      expect(first.first.resources.first.digest).not_to eq(second.first.resources.first.digest)
      expect(described_class.for(:readonly, root: root)).to be_empty
    end
  end

  it "follows the mcp_skills_enabled setting, off by default" do
    expect(described_class.enabled?).to be(false)
    AppSettings.mcp_skills_enabled = true
    expect(described_class.enabled?).to be(true)
  ensure
    AppSettings.where(var: "mcp_skills_enabled").delete_all
  end

  it "rejects an unknown profile" do
    expect { described_class.for(:bogus) }.to raise_error(GraphMem::McpProfile::InvalidProfile)
  end
end
