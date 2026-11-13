# frozen_string_literal: true

require "rails_helper"

# 1.86.0 (B1): the detail pane of a lifecycle_corruption row says what's wrong and what Repair does.
RSpec.describe "Review & Fix: lifecycle corruption", type: :request do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:fact) { fs_fact!(widget, "SynthWidget renders with the canvas backend.") }
  let!(:old) { fs_observe!(widget, "SynthWidget renders with the SVG backend.") }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html" } }

  def sweep_row
    issues = GraphIntegrityService.new.send(:detect_observation_lifecycle_corruption)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "integrity_sweep",
                                        items: issues.map { |issue| issue.merge(id: SecureRandom.uuid) }).sole
  end

  before { sign_in_operator }

  it "shows the issue, the Repair preview and a Repair button, and repairs the row" do
    old.update_columns(status: "superseded", obsoleted_at: 1.day.ago, outdated_by_id: fact.id, superseded_by_id: nil)
    row = sweep_row

    get review_row_path(row.row_uuid)
    expect(response.body).to include('data-testid="lifecycle-corruption-issue"', "no superseded_by reference",
                                     "SynthWidget renders with the SVG backend.", "Sets superseded_by of ##{old.id} to ##{fact.id}",
                                     "Repair…")
    get review_row_preview_path(row.row_uuid)
    expect(response.body).to include('data-testid="preview-confirm"', ">Repair<", "Repair: Observation ##{old.id}: superseded observation")

    post review_row_apply_path(row.row_uuid), headers: turbo
    expect(response).to have_http_status(:ok)
    expect(old.reload.superseded_by_id).to eq(fact.id)
  end

  it "offers Dismiss only for a cross-entity superseded_by" do
    beta = fs_member!(gadget, "Beta Service")
    elsewhere = fs_observe!(beta, "Beta Service renders with the canvas backend.")
    old.update_columns(status: "superseded", obsoleted_at: 1.day.ago, superseded_by_id: elsewhere.id)
    row = sweep_row

    get review_row_path(row.row_uuid)
    expect(response.body).to include("another entity", 'data-testid="detail-dismiss"')
    expect(response.body).not_to include("Repair…")
  end
end
