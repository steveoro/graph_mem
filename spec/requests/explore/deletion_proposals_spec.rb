# frozen_string_literal: true

require "rails_helper"

# UI-4b W7: Propose deletion seeds a Review & Fix row; Explore never deletes. Synthetic data.
RSpec.describe "Explore deletion proposals", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  def propose(entity, reason: nil)
    post propose_deletion_explore_entity_path(entity), params: { reason: reason }.compact, headers: stream_headers
  end

  it_behaves_like "an operator-only Explore write", -> { propose(widget) }

  context "as the operator" do
    before { sign_in_operator }

    it "seeds one delete_entity row (source operator), links to it, and deletes nothing" do
      expect { propose(widget, reason: "Synthetic duplicate") }.not_to change(MemoryEntity, :count)

      expect(response).to have_http_status(:ok)
      row = MaintenanceReportRow.sole
      expect(row).to have_attributes(report_type: "scan_review", kind: "delete_entity", status: "active")
      expect(row.payload).to include("entity_id" => widget.id, "reason" => "Synthetic duplicate")
      expect(row.maintenance_report.data["source"]).to eq("operator")
      expect(ChangeSet.count).to eq(0)
      expect(toast_text).to include("Deletion proposed for review.")
      expect(turbo_stream_for("update", "toasts").at_css("[data-testid='toast-link']")["href"]).to eq(review_row_path(row.row_uuid))
    end

    it "says Already proposed and links to the pending row the second time" do
      propose(widget)
      row = MaintenanceReportRow.sole

      propose(widget)

      expect(MaintenanceReportRow.count).to eq(1)
      expect(toast_text).to include("Already proposed.")
      expect(turbo_stream_for("update", "toasts").at_css("[data-testid='toast-link']")["href"]).to eq(review_row_path(row.row_uuid))
    end

    it "refuses a project root and an over-long reason" do
      propose(alpha)
      expect(response).to have_http_status(:unprocessable_content)
      propose(widget, reason: "x" * (ExploreEdits::MAX_REASON_LENGTH + 1))
      expect(response).to have_http_status(:unprocessable_content)
      expect(MaintenanceReportRow.count).to eq(0)
    end
  end
end
