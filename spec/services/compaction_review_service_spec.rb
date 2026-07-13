# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompactionReviewService, type: :service do
  let!(:report) do
    MaintenanceReport.create!(
      report_type: "compaction_review",
      data: {
        "run_id" => 1,
        "phase" => "tree_walk",
        "count" => 3,
        "items" => [
          {
            "id" => "merge-1",
            "kind" => "entity_merge",
            "entity_a" => { "entity_id" => 1, "name" => "Foo", "entity_type" => "Task" },
            "entity_b" => { "entity_id" => 2, "name" => "Bar", "entity_type" => "Task" },
            "cosine_distance" => 0.12,
            "score" => 0.88
          },
          {
            "id" => "orphan-1",
            "kind" => "orphan_parent",
            "entity_id" => 3,
            "entity_name" => "Orphan",
            "entity_type" => "Task",
            "suggested_parents" => [
              { "project_id" => 10, "project_name" => "Project X", "score" => 0.9 }
            ],
            "score" => 0.9
          },
          {
            "id" => "relation-1",
            "kind" => "relationship_proposal",
            "from_entity_id" => 4,
            "from_name" => "Issue A",
            "from_entity_type" => "Issue",
            "to_entity_id" => 5,
            "to_name" => "Solution B",
            "to_entity_type" => "PossibleSolution",
            "relation_type" => "solves",
            "confidence_band" => "high",
            "score" => 10
          }
        ]
      }
    )
  end

  describe ".latest_report" do
    it "returns the latest compaction review report" do
      expect(described_class.latest_report).to eq(report)
    end
  end

  describe ".items" do
    it "paginates active items with root nodes first" do
      items = described_class.items(report)

      expect(items.count).to eq(3)
      expect(items.first["kind"]).to eq("orphan_parent")
    end

    it "filters ignored items" do
      described_class.mark_ignored(report, "merge-1")

      items = described_class.items(report)
      expect(items.count).to eq(2)
      expect(items.map { |i| i["id"] }).not_to include("merge-1")
    end
  end

  describe ".mark_ignored" do
    it "marks the item as ignored" do
      expect(described_class.mark_ignored(report, "merge-1")).to be true
      expect(described_class.find_item(report, "merge-1")["status"]).to eq("ignored")
    end

    it "returns false when the item is missing" do
      expect(described_class.mark_ignored(report, "missing")).to be false
    end
  end

  describe ".apply_action" do
    it "returns an error for unknown kinds" do
      result = described_class.apply_action({ "kind" => "unknown" }, {})

      expect(result[:success]).to be false
    end
  end
end
