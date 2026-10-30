# frozen_string_literal: true

require "rails_helper"

# Fact supersede F4 (Decision 8): off by default; when on, only confident, unguarded, scoped rows
# of operator-confirmed facts. The AutoApply hard rule still refuses every other choice and
# destructive kind.
RSpec.describe ReviewPolicies::AutoApplyFactSupersede do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.") }

  after { AppSettings.where(var: %w[enable_auto_apply_fact_supersede auto_apply_fact_supersede_min_confidence]).delete_all }

  def judged(fact, verdict: "superseded", confidence: 0.95, replacement: nil)
    allow(FactSupersede::Judge).to receive(:call) do |_fact, candidates|
      candidates.map do |candidate|
        FactSupersede::Judge::Verdict.new(candidate: candidate, verdict: verdict, confidence: confidence, replacement: replacement, judged: true)
      end
    end
    FactSupersedeJob.perform_now(fact.id)
    MaintenanceReportRow.where(kind: "fact_supersede", status: "active")
  end

  def run = described_class.new.call

  it "is off by default" do
    judged(fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]))

    expect(run).to include("disabled" => true)
    expect(old.reload).to be_active
  end

  context "when turned on" do
    before { AppSettings.enable_auto_apply_fact_supersede = true }

    it "applies a confident row of an operator-confirmed fact in a policy change set" do
      fact = fs_fact!(gadget, tags: [ "replaces:fast-mcp" ])
      judged(fact, replacement: "The MCP server runs on the mcp gem.")

      stats = run

      expect(stats["acted"]).to eq(1)
      expect(old.reload).to have_attributes(status: "superseded", outdated_by_id: fact.id)
      expect(ChangeSet.find_by!(uuid: stats["change_sets"].sole).kind).to eq("policy.auto_apply_fact_supersede")
    end

    it "never applies an agent-marked fact's rows, a low confidence, a guarded or an unscoped row" do
      judged(fs_fact!(gadget, actor: FactSupersedeHelpers::AGENT_ACTOR, tags: [ "replaces:fast-mcp" ]))
      expect(run["acted"]).to eq(0)

      MaintenanceReportRow.delete_all
      judged(fs_fact!(gadget, "The MCP server uses the official mcp gem now.", tags: [ "replaces:fast-mcp" ]), confidence: 0.85)
      expect(run["acted"]).to eq(0)

      MaintenanceReportRow.delete_all
      old.update_active!(content: "On v1.7 the MCP server ran on fast-mcp.")
      loose = MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")
      MemoryRelation.create!(from_entity: gadget, to_entity: loose, relation_type: "depends_on")
      fs_observe!(loose, "Alpha Service talks to fast-mcp.")
      rows = judged(fs_fact!(gadget, "The MCP server is the mcp gem.", tags: [ "replaces:fast-mcp" ]))
      expect(rows.map { |row| [ row.payload["guard"], row.payload.dig("signals", "scoped") ] }).to contain_exactly([ "context", true ], [ nil, false ])
      expect(run["acted"]).to eq(0)
      expect(MemoryObservation.inactive.where(memory_entity_id: [ widget.id, loose.id ])).to be_empty
    end

    it "never applies an unjudged row" do
      judged(fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]), verdict: "unjudged", confidence: 0.5)
      AppSettings.auto_apply_fact_supersede_min_confidence = 0.8

      expect(run["acted"]).to eq(0)
    end
  end

  it "lifts the AutoApply hard rule for fact_supersede only" do
    policy = described_class.new
    other = ReviewPolicies::AutoApplyRelationships.new

    expect(policy.send(:applicable_kind?, "fact_supersede")).to be true
    (ReviewRowClassifier::CHOICE_KINDS + ReviewRowClassifier::DESTRUCTIVE_KINDS - [ "fact_supersede" ]).each do |kind|
      expect(policy.send(:applicable_kind?, kind)).to be(false), kind
    end
    (ReviewRowClassifier::CHOICE_KINDS + ReviewRowClassifier::DESTRUCTIVE_KINDS).each do |kind|
      expect(other.send(:applicable_kind?, kind)).to be(false), kind
    end
  end
end
