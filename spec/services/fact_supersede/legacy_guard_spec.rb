# frozen_string_literal: true

require "rails_helper"

# Fact supersede F2: old is not wrong; other projects, versions, environments and work logs are kept.
RSpec.describe FactSupersede::LegacyGuard do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:legacy) { MemoryEntity.create!(name: "Legacy Gadget", entity_type: "Project", aliases: "LGadget|Old Gadget") }
  let(:fact) { fs_fact!(gadget) }
  let(:guard) { described_class.new(fact) }

  def check(content, **attributes) = guard.check(fs_observe!(widget, content, **attributes))

  it "keeps a statement that names another project, by name or alias" do
    expect(check("Legacy Gadget still uses fast-mcp.")).to eq([ "keep", "names another project (Legacy Gadget)" ])
    expect(check("lgadget pins fast-mcp.").first).to eq("keep")
    expect(check("The Old Gadget docs mention fast-mcp.").first).to eq("keep")
  end

  it "doesn't count the fact's own project name as another project" do
    MemoryEntity.create!(name: "Gadget", entity_type: "Project")

    expect(check("Gadget Project runs on fast-mcp.")).to eq([ nil, nil ])
    expect(check("Gadget runs on fast-mcp.").first).to eq("keep")
  end

  it "keeps another project whose name contains the fact's project name" do
    own = fs_project!("Gadget")
    MemoryEntity.create!(name: "Gadget Mobile", entity_type: "Project")
    nested = described_class.new(fs_fact!(own))

    expect(nested.check(fs_observe!(own, "Gadget Mobile still runs on fast-mcp."))).to eq([ "keep", "names another project (Gadget Mobile)" ])
    expect(nested.check(fs_observe!(own, "Gadget runs on fast-mcp."))).to eq([ nil, nil ])
  end

  it "looks the project names up once, whatever the number of statements" do
    statements = Array.new(5) { |i| fs_observe!(widget, "Statement #{i} about fast-mcp.") }
    guard.check(statements.first)
    queries = 0
    counter = ->(*, payload) { queries += 1 if payload[:sql].include?("memory_entities") }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { statements.each { |statement| guard.check(statement) } }

    expect(queries).to eq(0)
  end

  it "puts a version, an environment word or a work-log entry in context" do
    expect(check("On v1.7 we pinned fast-mcp.")).to eq([ "context", "names a version the fact doesn't (v1.7)" ])
    expect(check("The staging server runs fast-mcp.").first).to eq("context")
    expect(check("Switched the MCP server to fast-mcp today.", perspective: "experience"))
      .to eq([ "context", "a work-log entry (true when written)" ])
    expect(check("The MCP server runs on fast-mcp.")).to eq([ nil, nil ])
  end

  it "ignores a version or environment the fact names too" do
    versioned = described_class.new(fs_fact!(gadget, "Since v1.7 production uses the mcp gem."))

    expect(versioned.check(fs_observe!(widget, "In production v1.7 ran on fast-mcp."))).to eq([ nil, nil ])
  end

  it "sets guard and guard_reason on candidates" do
    fs_observe!(widget, "Legacy Gadget runs on fast-mcp.")
    candidates = FactSupersede::Candidates.call(fs_fact!(gadget, tags: [ "replaces:fast-mcp" ])).candidates

    expect(guard.apply(candidates).sole).to have_attributes(guard: "keep", guard_reason: include("Legacy Gadget"))
  end
end
