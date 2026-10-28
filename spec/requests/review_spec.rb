# frozen_string_literal: true

require "rails_helper"

# UI-5b C2: /review (operator only).
RSpec.describe "Review & Fix", type: :request do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html" } }

  def seed(*items)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test",
                                        items: items.map { |item| item.merge(id: SecureRandom.uuid) })
  end

  def proposal(from = widget, to = beta, type: "depends_on")
    seed({ kind: "relationship_proposal", from_entity_id: from.id, to_entity_id: to.id, relation_type: type,
           confidence_band: "high", score: 14 }).sole
  end

  context "as the operator" do
    before { sign_in_operator }

    it "renders every view, the group frame, the detail pane and the previews" do
      row = proposal
      %w[attention kind project errors scan resolved policies].each do |view|
        get review_path(view: view)
        expect(response).to have_http_status(:ok), view
      end
      get review_path(q: "SynthWidget")
      expect(response.body).to include("Results for")
      get review_group_path(key: row.group_key)
      expect(response.body).to include(row.row_uuid)
      get review_row_path(row.row_uuid)
      expect(response.body).to include('data-testid="review-detail-card"', "Creates &#39;SynthWidget&#39; depends_on &#39;Beta Service&#39;")
      get review_row_preview_path(row.row_uuid)
      expect(response.body).to include('data-testid="review-preview-card"')
      get review_group_preview_path(key: row.group_key, op: "apply")
      expect(response.body).to include('data-testid="group-preview-card"')
    end

    it "applies a row with an Undo toast, and the Undo button reverts it" do
      row = proposal

      post review_row_apply_path(row.row_uuid), headers: turbo

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('target="toasts"', 'data-testid="toast-undo-button"', "remove", "maintenance_report_row_#{row.id}")
      uuid = ChangeSet.find(row.reload.change_set_id).uuid
      post undo_change_path(uuid), headers: { "HTTP_REFERER" => review_path }
      expect(row.reload.status).to eq("active")
    end

    it "says why when the action can't be undone" do
      row = seed({ kind: "delete_entity", entity_id: beta.id, reason: "synthetic" }).sole

      post review_row_apply_path(row.row_uuid), headers: turbo

      expect(response.body).to include("can&#39;t be undone: entity deleted")
      expect(response.body).not_to include("toast-undo")
    end

    it "dismisses, snoozes, restores and edits a row" do
      row = proposal
      post review_row_snooze_path(row.row_uuid), params: { days: 7 }, headers: turbo
      expect(row.reload.status).to eq("ignored")
      post review_row_dismiss_path(row.row_uuid), params: { reason: "synthetic" }, headers: turbo
      expect(row.reload.status).to eq("dismissed")
      post review_row_restore_path(row.row_uuid), headers: turbo
      expect(row.reload.status).to eq("active")
      patch review_row_path(row.row_uuid), params: { relation_type: "relates_to" }, headers: turbo
      expect(response).to have_http_status(:ok)
      expect(row.reload.effective_payload["relation_type"]).to eq("relates_to")
    end

    it "keeps one side of a contradiction" do
      kept = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget is fast.")
      other = MemoryObservation.create!(memory_entity: beta, content: "SynthWidget is not fast.")
      row = seed({ kind: "contradiction", observation_id_1: kept.id, observation_id_2: other.id, confidence: 0.9 }).sole

      get review_row_path(row.row_uuid)
      expect(response.body).to include('data-testid="keep-this-1"', "Both are right")
      post review_row_apply_path(row.row_uuid), params: { keep_observation_id: kept.id }, headers: turbo

      expect(response).to have_http_status(:ok)
      expect(other.reload.status).to eq("obsolete")
    end

    it "runs group actions, answering 409 when the group changed since the preview" do
      row = proposal
      preview = ReviewGroupActions.preview(group_key: row.group_key, op: "apply")
      post review_group_apply_path, params: { key: row.group_key, token: "stale", row_uuids: [ row.row_uuid ] }, headers: turbo
      expect(response).to have_http_status(:conflict)
      expect(response.body).to include("Review the preview again")

      post review_group_apply_path, params: { key: row.group_key, token: preview[:token], row_uuids: [ row.row_uuid ] }, headers: turbo
      expect(response).to have_http_status(:ok)
      expect(row.reload.status).to eq("approved")
    end

    it "answers 422 for a refused action and for a destructive group apply" do
      row = proposal
      CompactionReviewService.dismiss(row.row_uuid)
      post review_row_snooze_path(row.row_uuid), headers: turbo
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Only active or snoozed suggestions can be snoozed")

      merge = seed({ kind: "entity_merge", entity_a: { entity_id: widget.id }, entity_b: { entity_id: beta.id }, cosine_distance: 0.1 }).sole
      token = ReviewGroupActions.preview(group_key: merge.group_key, op: "apply")[:token]
      post review_group_apply_path, params: { key: merge.group_key, token: token, row_uuids: [ merge.row_uuid ] }, headers: turbo
      expect(response).to have_http_status(:unprocessable_content)
      expect(MemoryEntity.exists?(widget.id)).to be(true)
    end

    it "answers 404 for an unknown row" do
      post review_row_apply_path(SecureRandom.uuid), headers: turbo

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("That suggestion no longer exists.")
    end

    it "answers 404 in the frame for a GET of a missing row" do
      get review_row_path(SecureRandom.uuid), headers: { "Turbo-Frame" => "review-detail" }

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('<turbo-frame id="review-detail">', "That suggestion no longer exists.")
    end

    it "answers 422 with the applier's reason when the graph changed under the row" do
      row = proposal
      beta.destroy!

      post review_row_apply_path(row.row_uuid), headers: turbo

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include("That suggestion no longer exists.")
      expect(row.reload.status).to eq("active")
    end

    it "shows an alert when the suggest-merges import fails" do
      allow_any_instance_of(SuggestMergesTool).to receive(:call).and_raise(StandardError, "synthetic outage")

      post review_import_suggest_merges_path, headers: turbo

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Import failed: synthetic outage")
    end

    it "answers 503 when the membership lock is busy or the database reports a transient lock error" do
      row = proposal
      allow(CompactionReviewService).to receive(:apply).and_raise(ProjectMembership::LockTimeout, "synthetic")
      post review_row_apply_path(row.row_uuid), headers: turbo
      expect(response).to have_http_status(:service_unavailable)

      allow(CompactionReviewService).to receive(:apply).and_raise(ActiveRecord::Deadlocked, "synthetic")
      post review_row_apply_path(row.row_uuid), headers: turbo
      expect(response).to have_http_status(:service_unavailable)
      expect(response.body).to include("Retry shortly.")
    end

    it "redirects an HTML action back with 303" do
      row = proposal

      post review_row_dismiss_path(row.row_uuid), params: { return_to: "/review?view=kind" }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/review?view=kind")
    end

    it "queues a policy run and imports suggest-merges" do
      expect { post review_run_policies_path, headers: turbo }.to have_enqueued_job(ReviewPolicyJob).with(trigger: "manual")
      allow_any_instance_of(SuggestMergesTool).to receive(:call).and_return(suggestions: [
        { entity_a: { entity_id: widget.id, name: widget.name }, entity_b: { entity_id: beta.id, name: beta.name }, cosine_distance: 0.1 }
      ])
      expect { post review_import_suggest_merges_path, headers: turbo }.to change { MaintenanceReportRow.where(kind: "entity_merge").count }.by(1)
    end

    it "lists resolved rows with Undo, or Restore and the reason when the set can't be undone" do
      undoable = proposal
      CompactionReviewService.dismiss(undoable.row_uuid)
      gone = seed({ kind: "delete_entity", entity_id: beta.id }).sole
      CompactionReviewService.apply(gone.row_uuid)

      get review_path(view: "resolved")

      expect(response.body).to include('data-testid="resolved-undo"', 'data-testid="resolved-not-undoable"', "can&#39;t be undone: entity deleted")
    end

    it "lists scan_review rows under Scan review and filters By kind" do
      scan = CompactionReviewService.seed_report(report_type: "scan_review", source: "test",
                                                 items: [ { id: SecureRandom.uuid, kind: "delete_entity", entity_id: beta.id, reason: "gone" } ]).sole
      compaction = proposal

      card_kinds = -> { Nokogiri::HTML(response.body).css("[data-testid='review-group'] .ui-badge").map(&:text) }
      get review_path(view: "scan")
      expect(card_kinds.call).to eq([ "Delete entity" ])
      get review_path(view: "kind", kind: "relationship_proposal")
      expect(card_kinds.call).to eq([ "Relationship proposal" ])
      expect([ scan.reload.status, compaction.reload.status ]).to eq(%w[active active])
    end

    it "sends an HTML action back to /review when return_to isn't a review page" do
      row = proposal

      post review_row_dismiss_path(row.row_uuid), params: { return_to: "dashboard" }

      expect(response).to redirect_to(review_path)
      expect(row.reload.status).to eq("dismissed")
    end

    it "redirects the old review URL (301), scan review to view=scan" do
      get "/data_exchange/compaction_review"
      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to("/review")
      get "/data_exchange/compaction_review", params: { report_type: "scan_review" }
      expect(response).to redirect_to("/review?view=scan")
    end

    it "requires the CSRF token" do
      row = proposal
      ActionController::Base.allow_forgery_protection = true

      post review_row_dismiss_path(row.row_uuid), headers: turbo

      expect(response).to have_http_status(:unprocessable_content)
      expect(row.reload.status).to eq("active")
    ensure
      ActionController::Base.allow_forgery_protection = false
    end
  end

  it "answers a guest with 403 on /review and writes nothing" do
    row = proposal
    enable_guest!
    sign_in_guest

    get review_path
    expect(response).to have_http_status(:forbidden)
    expect { post review_row_dismiss_path(row.row_uuid), headers: turbo }.not_to change { row.reload.status }
    expect(response).to have_http_status(:forbidden)
  end

  it "sends a signed-out visitor to the sign-in page" do
    get review_path

    expect(response).to redirect_to(operator_login_path)
  end

  it "sends a guest who follows the old review URL to the 403 page" do
    enable_guest!
    sign_in_guest

    get "/data_exchange/compaction_review"
    follow_redirect!
    expect(response).to have_http_status(:forbidden)
  end
end
