# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UpdateObservationTool, type: :model do
  let(:tool) { described_class.new }
  let(:entity) { MemoryEntity.create!(name: 'Host Entity', entity_type: 'Project') }
  let(:observation) do
    MemoryObservation.create!(
      memory_entity: entity,
      content: 'Original',
      confidence: 0.7,
      source: 'spec',
      tags: [ 'current' ]
    )
  end

  describe '.tool_name' do
    it 'returns the correct tool name' do
      expect(described_class.tool_name).to eq('update_observation')
    end
  end

  describe '.input_schema_to_json' do
    it 'exposes lifecycle update arguments' do
      schema = described_class.input_schema_to_json

      expect(schema[:required]).to eq([ 'observation_id' ])
      expect(schema[:properties].keys).to include(
        :observation_id, :text_content, :confidence, :source, :valid_from,
        :valid_until, :tags, :supersede, :reason
      )
    end
  end

  describe '#call' do
    it 'updates an active observation in place' do
      result = tool.call(
        observation_id: observation.id,
        confidence: 0.9,
        tags: [ 'verified' ]
      )

      expect(result).to include(
        observation_id: observation.id,
        observation_content: 'Original',
        confidence: 0.9,
        tags: [ 'verified' ],
        status: MemoryObservation::ACTIVE_STATUS,
        superseded_observation_id: nil
      )
      expect(observation.reload.confidence).to eq(0.9)
    end

    it 'supersedes an observation and returns the active replacement' do
      result = tool.call(
        observation_id: observation.id,
        text_content: 'Corrected',
        supersede: true,
        reason: 'Correction'
      )

      replacement = MemoryObservation.find(result[:observation_id])
      expect(replacement).to be_active
      expect(replacement).to have_attributes(content: 'Corrected', source: 'spec', tags: [ 'current' ])
      expect(result[:superseded_observation_id]).to eq(observation.id)
      expect(observation.reload).to be_superseded
      expect(observation.superseded_by).to eq(replacement)
      expect(observation.obsolescence_reason).to eq('Correction')
    end

    it 'rejects calls without mutable attributes' do
      expect {
        tool.call(observation_id: observation.id)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /At least one/)
    end

    it 'rejects updates to inactive observations' do
      observation.mark_obsolete!

      expect {
        tool.call(observation_id: observation.id, text_content: 'Changed')
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Inactive observations/)
    end

    it 'maps validation errors to invalid arguments' do
      expect {
        tool.call(observation_id: observation.id, confidence: 1.5)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Validation Failed/)
    end

    it 'raises ResourceNotFound for a missing observation' do
      expect {
        tool.call(observation_id: 999_999, text_content: 'Changed')
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/)
    end
  end
end
