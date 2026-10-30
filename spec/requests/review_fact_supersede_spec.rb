# frozen_string_literal: true

require "rails_helper"

# Fact supersede F4 (Checkpoint 2): an operator fact on Gadget Project produces "Outdated by a
# fact" rows; the operator supersedes one from Review & Fix, and Undo restores it.
RSpec.describe "Review & Fix › Outdated by a fact", type: :request do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.") }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html" } }
  let(:row) do
    FactSupersedeJob.perform_now(fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]).id)
    MaintenanceReportRow.find_by!(kind: "fact_supersede")
  end

  context "as the operator" do
    before { sign_in_operator }

    it "lists the kind as Outdated by a fact, shows both sides, and supersedes with an edited replacement" do
      get review_path(view: "kind", kind: "fact_supersede")
      expect(response.body).to include("Outdated by a fact")

      get review_row_path(row.row_uuid)
      expect(response.body).to include('data-testid="fact-supersede-fact"', 'data-testid="fact-supersede-observation"',
                                       "The MCP server runs on fast-mcp.", "Judge: unjudged")
      expect(response.body).not_to include("Both are right")

      get review_row_preview_path(row.row_uuid, fact_action: "supersede")
      expect(response.body).to include('data-testid="fact-supersede-apply-form"', "The MCP server uses the official mcp gem.")

      post review_row_apply_path(row.row_uuid), params: { fact_action: "supersede", replacement: "The MCP server runs on the mcp gem." }, headers: turbo
      expect(response).to have_http_status(:ok)
      expect(old.reload).to have_attributes(status: "superseded", outdated_by_id: row.payload["fact_observation_id"])

      post undo_change_path(ChangeSet.find(row.reload.change_set_id).uuid), headers: { "HTTP_REFERER" => review_path }
      expect(old.reload).to have_attributes(status: "active", outdated_by_id: nil)
      expect(row.reload.status).to eq("active")
    end

    it "retires from the preview" do
      get review_row_preview_path(row.row_uuid, fact_action: "retire")
      expect(response.body).not_to include('name="replacement"')

      post review_row_apply_path(row.row_uuid), params: { fact_action: "retire" }, headers: turbo
      expect(old.reload).to have_attributes(status: "obsolete", outdated_by_id: row.payload["fact_observation_id"])
    end
  end

  it "answers a guest with 403" do
    enable_guest!
    sign_in_operator(username: "guest", password: OperatorAuthHelpers::TEST_GUEST_PASSWORD)

    post review_row_apply_path(row.row_uuid), params: { fact_action: "retire" }, headers: turbo
    expect(response).to have_http_status(:forbidden)
    expect(old.reload).to be_active
  end
end
