# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GetCurrentTimeTool, type: :model do
  let(:tool) { described_class.new }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('get_current_time')
      end
    end

    describe '.description' do
      it 'returns a non-empty description' do
        expect(tool.description).to be_a(String)
        expect(tool.description).not_to be_empty
      end
    end
  end

  describe '#input_schema_to_json' do
    it 'returns an empty-properties schema (no arguments)' do
      schema = tool.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:properties]).to eq({})
      expect(schema[:required]).to eq([])
    end
  end

  describe '#call' do
    it 'returns a hash with a timestamp key' do
      result = tool.call
      expect(result).to have_key(:timestamp)
    end

    it 'returns a valid ISO 8601 UTC timestamp' do
      result = tool.call
      parsed = Time.iso8601(result[:timestamp])
      expect(parsed).to be_a(Time)
      expect(parsed.utc?).to be true
    end

    it 'returns a timestamp close to the current time' do
      before = Time.now.utc
      result = tool.call
      after = Time.now.utc

      parsed = Time.iso8601(result[:timestamp])
      expect(parsed).to be >= before - 1.second
      expect(parsed).to be <= after + 1.second
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        frozen_time = Time.now.utc
        allow(Time).to receive(:now).and_return(frozen_time)
        allow(frozen_time).to receive(:utc).and_raise(StandardError.new("clock failure"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError, /Error in GetCurrentTimeTool/)
      end
    end
  end
end
