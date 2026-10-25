# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMutationBatch do
  describe ".execute" do
    let(:operation) { { type: "create_relation", index: 2, attributes: {} } }

    it "prefixes an AmbiguousReference and keeps its class, category, next_move and candidates" do
      candidates = [ MemoryEntity.new(id: 1, name: "Dup", entity_type: "Task", project_id: 7) ]

      expect {
        described_class.execute(operation) { raise McpGraphMemErrors::AmbiguousReference.new("Dup", candidates) }
      }.to raise_error(McpGraphMemErrors::AmbiguousReference, /\Acreate_relation\[2\]: Name 'Dup' is ambiguous.*entity_id: 1/) { |error|
        expect(error.category).to eq("ambiguous_name")
        expect(error.next_move).to include("set_context")
      }
    end

    it "prefixes any McpGraphMemErrors::Error and keeps category, retriable, next_move and code" do
      original = McpGraphMemErrors::OperationFailed.new(
        "Refused", category: "validation", retriable: true, next_move: "Do this.", code: "some_code"
      )

      expect { described_class.execute(operation) { raise original } }.to raise_error(McpGraphMemErrors::OperationFailed) { |error|
        expect(error.message).to eq("create_relation[2]: Refused")
        expect([ error.category, error.retriable, error.next_move, error.code ]).to eq([ "validation", true, "Do this.", "some_code" ])
      }
    end
  end
end
