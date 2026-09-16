# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolTelemetry do
  describe ".record" do
    it "logs and persists a privacy-safe invocation" do
      result = described_class.record(
        tool_name: "search_entities",
        client_id: "cursor-test",
        outcome: "ok",
        duration_ms: 17,
        result_size: 3,
        scope: "project",
        argument_keys: [ :query, "limit", "query" ]
      )

      expect(result).to be_persisted
      expect(result).to have_attributes(
        tool_name: "search_entities",
        client_id: "cursor-test",
        outcome: "ok",
        duration_ms: 17,
        result_size: 3,
        scope: "project",
        error_class: nil,
        error_category: nil,
        argument_keys: %w[limit query]
      )
    end

    it "persists error details" do
      invocation = described_class.record(
        tool_name: "create_entity",
        client_id: "cursor-test",
        outcome: "error",
        duration_ms: 2,
        error_class: "FastMcp::Tool::InvalidArgumentsError",
        error_category: "validation",
        argument_keys: [ "entity_type" ]
      )

      expect(invocation).to have_attributes(
        outcome: "error",
        error_class: "FastMcp::Tool::InvalidArgumentsError",
        error_category: "validation",
        result_size: nil
      )
    end

    it "does not let a persistence failure affect the tool call" do
      logger = instance_spy(ActiveSupport::Logger)
      allow(Rails).to receive(:logger).and_return(logger)
      allow(ToolInvocation).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished, "offline")

      expect {
        described_class.record(
          tool_name: "get_context",
          client_id: "cursor-test",
          outcome: "ok",
          duration_ms: 1,
          argument_keys: []
        )
      }.not_to raise_error
      expect(logger).to have_received(:warn).with(/persistence failed.*offline/)
    end
  end
end
