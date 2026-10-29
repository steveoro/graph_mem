# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DetectContradictionsTool, type: :model do
  let(:tool) { described_class.new }
  let!(:entity) { MemoryEntity.create!(name: 'Contradiction Entity', entity_type: 'Project') }

  describe '.tool_name' do
    it 'returns the correct tool name' do
      expect(described_class.tool_name).to eq('detect_contradictions')
    end
  end

  describe '#input_schema_to_json' do
    it 'includes entity_id and optional parameters' do
      schema = described_class.input_schema_to_json
      expect(schema[:required]).to eq([ 'entity_id' ])
      expect(schema[:properties]).to have_key(:max_distance)
      expect(schema[:properties]).to have_key(:max_results)
    end
  end

  describe '#call' do
    it 'raises ResourceNotFound for a missing entity' do
      expect {
        tool.call(entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/) do |error|
        expect(error.next_move).to include('`search`')
        expect(error.next_move).to include('`detect_contradictions`')
      end
    end

    it 'raises InternalServerError on unexpected errors without leaking details' do
      allow(MemoryEntity).to receive(:find).and_raise(StandardError.new("unexpected secret"))

      expect {
        tool.call(entity_id: entity.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, /unexpected error/) do |error|
        expect(error.message).not_to include('secret')
      end
    end

    it 're-raises timeout errors' do
      allow(MemoryEntity).to receive(:find).and_raise(Timeout::Error.new("execution expired"))

      expect {
        tool.call(entity_id: entity.id)
      }.to raise_error(Timeout::Error, /execution expired/)
    end

    it 'returns an empty candidate list when no contradictions exist' do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)

      result = tool.call(entity_id: entity.id)

      expect(result[:entity_id]).to eq(entity.id)
      expect(result[:candidate_count]).to eq(0)
      expect(result[:candidates]).to eq([])
    end

    it 'answers the default mode exactly as before (no mode, or mode "contradictions")' do
      pair = ContradictionDetector::Result.new(observation_id_1: 3, observation_id_2: 9, distance: 0.1, confidence: 0.9)
      allow(ContradictionDetector).to receive(:detect).and_return([ pair ])
      expected = { entity_id: entity.id, name: entity.name, candidate_count: 1,
                   candidates: [ { observation_id_1: 3, observation_id_2: 9, distance: 0.1, confidence: 0.9 } ] }

      expect(tool.call(entity_id: entity.id)).to eq(expected)
      expect(tool.call(entity_id: entity.id, mode: "contradictions")).to eq(expected)
      expect(ContradictionDetector).to have_received(:detect).with(entity.id, max_distance: 0.35, max_results: 20, persist: true).twice
    end

    it "refuses the fact arguments without mode outdated_by_fact, and an unknown mode" do
      expect { tool.call(entity_id: entity.id, fact_observation_id: 1) }
        .to raise_error(McpGraphMemErrors::InvalidArguments, /only work with mode "outdated_by_fact"/)
      expect { tool.call(entity_id: entity.id, terms: [ "fast-mcp" ]) }.to raise_error(McpGraphMemErrors::InvalidArguments)
      expect { tool.call(entity_id: entity.id, mode: "everything") }.to raise_error(McpGraphMemErrors::InvalidArguments, /Unknown mode/)
    end
  end

  describe 'mode "outdated_by_fact" (fact supersede F6)' do
    let!(:gadget) { fs_project!("Gadget Project") }
    let!(:widget) { fs_member!(gadget, "SynthWidget") }
    let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.") }
    let!(:fact) { fs_fact!(gadget) }

    def run(**args) = tool.call(entity_id: gadget.id, mode: "outdated_by_fact", fact_observation_id: fact.id, **args)

    it "seeds proposals with their review row ids, and writes no observation" do
      result = run(terms: [ "fast-mcp" ])

      row = MaintenanceReportRow.find_by!(kind: "fact_supersede")
      expect(result).to include(mode: "outdated_by_fact", fact_observation_id: fact.id, searched: true, judged: false,
                                proposal_count: 1, seeded_count: 1)
      expect(result[:proposals].sole).to include("observation_id" => old.id, "verdict" => "unjudged", "review_row_id" => row.row_uuid)
      expect(old.reload).to be_active
    end

    it "only proposes with seed_review false, and says when there was nothing to search" do
      expect(run(terms: [ "fast-mcp" ], seed_review: false)).to include(proposal_count: 1, seeded_count: 0)
      expect(run[:proposals].first&.dig("review_row_id")).to be_nil
      expect(run).to include(searched: false, proposal_count: 0)
      expect(MaintenanceReportRow.where(kind: "fact_supersede")).to be_empty
    end

    it "refuses a missing or foreign fact_observation_id, a non-fact, bad terms and max_results above 50" do
      expect { tool.call(entity_id: gadget.id, mode: "outdated_by_fact") }
        .to raise_error(McpGraphMemErrors::InvalidArguments, /required/) { |error| expect(error.next_move).to include("`get_entities`") }
      expect { tool.call(entity_id: widget.id, mode: "outdated_by_fact", fact_observation_id: fact.id) }
        .to raise_error(McpGraphMemErrors::InvalidArguments, /not an active source fact of entity ##{widget.id}/)
      expect { tool.call(entity_id: widget.id, mode: "outdated_by_fact", fact_observation_id: old.id) }
        .to raise_error(McpGraphMemErrors::InvalidArguments, /not an active source fact/)
      expect { run(terms: %w[a1 a2 a3 a4 a5 a6]) }.to raise_error(McpGraphMemErrors::InvalidArguments, /at most 5/)
      expect { run(terms: [ "x" ]) }.to raise_error(McpGraphMemErrors::InvalidArguments)
      expect { run(max_results: 51) }.to raise_error(McpGraphMemErrors::InvalidArguments, /between 1 and 50/)
    end

    it "is applied through apply_maintenance_review" do
      run(terms: [ "fast-mcp" ])
      row = MaintenanceReportRow.find_by!(kind: "fact_supersede")

      ApplyMaintenanceReviewTool.new.call(item_id: row.row_uuid, action_params: { "fact_action" => "supersede", "replacement" => "The MCP server runs on the mcp gem." })

      expect(old.reload).to have_attributes(status: "superseded", outdated_by_id: fact.id)
    end
  end
end
