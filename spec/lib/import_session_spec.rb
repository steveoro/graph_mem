# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/import_session"

RSpec.describe ImportSession do
  let(:import_data) do
    {
      version: "1.0",
      root_nodes: [
        { name: "Test Project", entity_type: "Project", observations: [], children: [] }
      ]
    }
  end

  let(:matches) do
    [
      { import_node: { name: "Test", entity_type: "Project" }, matches: [], status: "new", node_path: "0" }
    ]
  end

  let(:stats) do
    { total: 1, high_confidence: 0, low_confidence: 0, new: 1 }
  end

  let(:version) { "1.0" }

  describe ".create" do
    it "creates a new session and returns a UUID" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      expect(session_id).to be_present
      expect(session_id).to match(/\A[0-9a-f\-]{36}\z/)

      # Cleanup
      described_class.cleanup(session_id)
    end
  end

  describe ".exists?" do
    it "returns true for existing session" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      expect(described_class.exists?(session_id)).to be true

      # Cleanup
      described_class.cleanup(session_id)
    end

    it "returns false for non-existing session" do
      expect(described_class.exists?("non-existent-id")).to be false
    end

    it "returns false for blank session_id" do
      expect(described_class.exists?(nil)).to be false
      expect(described_class.exists?("")).to be false
    end
  end

  describe ".load_data" do
    it "loads import data from a session" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      loaded_data = described_class.load_data(session_id)
      expect(loaded_data[:version]).to eq("1.0")
      expect(loaded_data[:root_nodes]).to be_an(Array)

      # Cleanup
      described_class.cleanup(session_id)
    end
  end

  describe ".load_matches" do
    it "loads match results from a session" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      loaded_matches = described_class.load_matches(session_id)
      expect(loaded_matches).to be_an(Array)
      expect(loaded_matches.first[:status]).to eq("new")

      # Cleanup
      described_class.cleanup(session_id)
    end
  end

  describe ".load_stats" do
    it "loads stats from a session" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      loaded_stats = described_class.load_stats(session_id)
      expect(loaded_stats[:total]).to eq(1)
      expect(loaded_stats[:new]).to eq(1)

      # Cleanup
      described_class.cleanup(session_id)
    end
  end

  describe ".load_version" do
    it "loads version from a session" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      loaded_version = described_class.load_version(session_id)
      expect(loaded_version).to eq("1.0")

      # Cleanup
      described_class.cleanup(session_id)
    end
  end

  describe ".store_report and .load_report" do
    let(:report) do
      { success: true, entities_created: 5, observations_created: 10, errors: [] }
    end

    it "stores and loads a report" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      described_class.store_report(session_id, report)
      loaded_report = described_class.load_report(session_id)

      expect(loaded_report[:success]).to be true
      expect(loaded_report[:entities_created]).to eq(5)

      # Cleanup
      described_class.cleanup(session_id)
    end
  end

  describe ".report_exists?" do
    it "returns true when report exists" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      described_class.store_report(session_id, { success: true })

      expect(described_class.report_exists?(session_id)).to be true

      # Cleanup
      described_class.cleanup(session_id)
    end

    it "returns false when report does not exist" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      expect(described_class.report_exists?(session_id)).to be false

      # Cleanup
      described_class.cleanup(session_id)
    end
  end

  describe ".cleanup" do
    it "removes all session files" do
      session_id = described_class.create(
        import_data: import_data,
        matches: matches,
        stats: stats,
        version: version
      )

      described_class.store_report(session_id, { success: true })

      expect(described_class.exists?(session_id)).to be true
      expect(described_class.report_exists?(session_id)).to be true

      described_class.cleanup(session_id)

      expect(described_class.exists?(session_id)).to be false
      expect(described_class.report_exists?(session_id)).to be false
    end

    it "handles nil session_id gracefully" do
      expect { described_class.cleanup(nil) }.not_to raise_error
    end
  end
end
