# frozen_string_literal: true

require "rails_helper"

# Fact supersede F4: the job seeds "Outdated by a fact" rows for superseded and unjudged
# candidates only, once per pair; the after_commit hook queues it for new and changed facts.
RSpec.describe FactSupersedeJob do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:legacy) { fs_project!("Legacy Gadget") }
  let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.") }
  let!(:fact) { fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]) }

  def rows = MaintenanceReportRow.where(kind: "fact_supersede")

  it "seeds an unjudged row at 0.5 or less without the LLM, and enqueues the review policies" do
    expect { described_class.perform_now(fact.id) }.to have_enqueued_job(ReviewPolicyJob).with(trigger: "fact_supersede")

    row = rows.sole
    expect(row.payload).to include("fact_observation_id" => fact.id, "observation_id" => old.id, "verdict" => "unjudged",
                                   "project_id" => gadget.id, "project_name" => "Gadget Project", "guard" => nil)
    expect(row.confidence.to_f).to be <= 0.5
    expect(row).to have_attributes(signature: "fact:#{fact.id}|obs:#{old.id}", project_id: gadget.id, anchor_entity_id: widget.id,
                                   group_key: "fact_supersede|fact:#{fact.id}")
    expect(OperationProgress.where(operation_type: "fact_supersede").sole).to have_attributes(status: "completed")
  end

  it "proposes nothing for the same sentence in Legacy Gadget, nor for one that names Legacy Gadget or a version" do
    fs_observe!(fs_member!(legacy, "Legacy SynthWidget"), "The MCP server runs on fast-mcp.")
    fs_observe!(widget, "Legacy Gadget still uses fast-mcp.")
    versioned = fs_observe!(widget, "On v1.7 the MCP server pinned fast-mcp.")

    described_class.perform_now(fact.id)

    expect(rows.map { |row| row.payload["observation_id"] }).to contain_exactly(old.id, versioned.id)
    expect(rows.find { |row| row.payload["observation_id"] == versioned.id }.payload["guard"]).to eq("context")
  end

  it "keeps only superseded and unjudged verdicts" do
    keep = fs_observe!(widget, "fast-mcp is vendored for the docs site.")
    gone = fs_observe!(widget, "fast-mcp had a logo.")
    allow(FactSupersede::Judge).to receive(:call) do |_fact, candidates|
      verdicts = { old.id => [ "superseded", 0.95 ], keep.id => [ "still_valid", 0.9 ], gone.id => [ "unrelated", 0.9 ] }
      candidates.map do |candidate|
        verdict, confidence = verdicts.fetch(candidate.observation.id)
        FactSupersede::Judge::Verdict.new(candidate: candidate, verdict: verdict, confidence: confidence, judged: true)
      end
    end

    described_class.perform_now(fact.id)

    expect(rows.sole.payload).to include("observation_id" => old.id, "verdict" => "superseded", "confidence" => 0.95)
  end

  it "doesn't duplicate on a re-run, and a dismissed pair stays suppressed" do
    2.times { described_class.perform_now(fact.id) }
    expect(rows.count).to eq(1)
    allow(FactSupersede::Judge).to receive(:call).and_call_original
    expect(described_class.perform_now(fact.id)).to have_attributes(known: 1)
    expect(FactSupersede::Judge).to have_received(:call).with(fact, [], max_batches: nil)

    CompactionReviewService.dismiss(rows.sole.row_uuid, reason: "synthetic: still true")
    described_class.perform_now(fact.id)
    expect(rows.active.count).to eq(0)
  end

  it "judges pending unjudged rows once the LLM is usable: superseded refreshes, still valid dismisses" do
    other = fs_observe!(widget, "fast-mcp is vendored for the docs site.")
    described_class.perform_now(fact.id)
    expect(rows.map { |row| row.payload["verdict"] }).to all(eq("unjudged"))

    allow(SummarizationConfig).to receive(:llm_usable?).and_return(true)
    allow(FactSupersede::Judge).to receive(:call) do |_fact, candidates|
      candidates.map do |candidate|
        verdict = candidate.observation.id == old.id ? [ "superseded", 0.95 ] : [ "still_valid", 0.9 ]
        FactSupersede::Judge::Verdict.new(candidate: candidate, verdict: verdict[0], confidence: verdict[1], judged: true)
      end
    end

    FactSupersede::Proposals.call(fact, seed: false)
    expect(FactSupersede::Judge).to have_received(:call).with(fact, [], max_batches: nil)

    expect(described_class.perform_now(fact.id)).to have_attributes(rejudged: 2, rows: [])
    refreshed = rows.find { |row| row.payload["observation_id"] == old.id }
    expect(refreshed).to have_attributes(status: "active", confidence: 0.95)
    expect(refreshed.payload).to include("verdict" => "superseded")
    expect(rows.find { |row| row.payload["observation_id"] == other.id })
      .to have_attributes(status: "dismissed", resolved_by: "generator", resolution_reason: "the judge found it still valid")
    expect(MaintenanceReportSuppression.count).to eq(0)
  end

  it "seeds rows for an agent-marked fact too" do
    agent_fact = fs_fact!(widget, "SynthWidget is served by the mcp gem.", actor: FactSupersedeHelpers::AGENT_ACTOR, tags: [ "replaces:fast-mcp" ])

    described_class.perform_now(agent_fact.id)

    expect(rows.map { |row| row.payload["fact_observation_id"] }).to eq([ agent_fact.id ])
  end

  it "records 'nothing to search' without vectors and terms, and is a no-op for a non-fact or with the feature off" do
    bare = fs_fact!(gadget, "The MCP server answers on /mcp.")
    described_class.perform_now(bare.id)
    expect(rows).to be_empty
    expect(OperationProgress.where(operation_type: "fact_supersede").sole.message).to start_with("Nothing to search")

    AppSettings.fact_supersede_enabled = false
    expect(described_class.perform_now(fact.id)).to be_nil
    expect(described_class.perform_now(old.id)).to be_nil
    expect(rows).to be_empty
  ensure
    AppSettings.where(var: "fact_supersede_enabled").delete_all
  end

  it "runs one job per fact at a time" do
    expect(described_class.new(fact.id).concurrency_key).to eq("FactSupersedeJob/fact:#{fact.id}")
    expect(described_class.concurrency_limit).to eq(1)
  end

  describe "the after_commit hook" do
    it "queues the job for a new fact, a fact's new text and a newly added tag" do
      expect { fs_fact!(widget, "SynthWidget uses Ruby 3.4.") }.to have_enqueued_job(described_class)
      expect { fact.update_active!(content: "The MCP server uses the mcp gem 1.8.") }.to have_enqueued_job(described_class).with(fact.id)
      expect { old.update_active!(tags: [ "source-fact" ]) }.to have_enqueued_job(described_class).with(old.id)
      expect { fact.supersede!({ content: "The MCP server uses mcp 1.8.2." }) }.to have_enqueued_job(described_class)
    end

    it "doesn't queue for other changes, plain observations, or with the feature off" do
      expect { fact.update_active!(confidence: 0.8) }.not_to have_enqueued_job(described_class)
      expect { fs_observe!(widget, "SynthWidget renders tiles.") }.not_to have_enqueued_job(described_class)

      AppSettings.fact_supersede_enabled = false
      expect { fs_fact!(widget, "SynthWidget uses Ruby 3.4.") }.not_to have_enqueued_job(described_class)
    ensure
      AppSettings.where(var: "fact_supersede_enabled").delete_all
    end
  end
end
