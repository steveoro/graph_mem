# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VersionTool, type: :model do
  let(:tool) { described_class.new }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('get_version')
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
    context 'with valid VERSION constant' do
      it 'returns a hash with the version string' do
        result = tool.call
        expect(result).to eq({ version: GraphMem::VERSION.to_s })
      end

      it 'returns a non-empty version string' do
        result = tool.call
        expect(result[:version]).to be_a(String)
        expect(result[:version]).not_to be_empty
      end
    end

    context 'when VERSION constant is undefined' do
      it 'raises InternalServerError' do
        allow(GraphMem).to receive(:const_missing).with(:VERSION).and_raise(NameError.new("uninitialized constant GraphMem::VERSION"))
        stub_const("GraphMem", Module.new)

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError, /Version information is currently unavailable/)
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        version_mod = Module.new
        version_mod.const_set(:VERSION, Class.new { def to_s; raise StandardError, "unexpected"; end }.new)
        stub_const("GraphMem", version_mod)

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError, /Internal Server Error/)
      end
    end
  end
end
