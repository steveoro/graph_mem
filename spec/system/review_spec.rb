# frozen_string_literal: true

require "rails_helper"

# UI-5b: the Review page in a browser (synthetic data).
RSpec.describe "Review & Fix", type: :system do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }

  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    sign_in_through_form
  end

  def seed(*items)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test",
                                        items: items.map { |item| item.merge(id: SecureRandom.uuid) })
  end

  it "applies a high-confidence group from its preview card, undoes it from the toast, and reaches inbox zero" do
    # Two relation types between one pair: one group of two.
    seed(*%w[depends_on relates_to].map do |type|
      { kind: "relationship_proposal", from_entity_id: widget.id, to_entity_id: beta.id, relation_type: type,
        confidence_band: "high", score: 14 }
    end)
    allow(AppSettings).to receive(:review_number).and_call_original
    allow(AppSettings).to receive(:review_number).with(:review_attention_threshold).and_return(1)

    visit review_path
    wait_for_stimulus
    click_link "Apply high-confidence"
    within("[data-testid='group-preview-card']") do
      expect(page).to have_text("Apply: 2 suggestions")
      click_button "Apply"
    end

    expect(page).to have_css("[data-testid='toast-undo']", text: "Applied 2 suggestion(s)")
    expect(MemoryRelation.where(from_entity_id: widget.id).count).to eq(2)
    within("[data-testid='toast-undo']") { click_button "Undo" }
    expect(page).to have_css(".ui-toast--notice", text: "Undone")
    expect(MemoryRelation.where(from_entity_id: widget.id)).not_to exist

    MaintenanceReportRow.update_all(status: "dismissed")
    visit review_path
    expect(page).to have_css("[data-testid='review-inbox-zero']", text: "Inbox zero")
    expect(csp_console_errors).to be_empty
  end

  it "keeps one side of a contradiction through the preview card, and Undo brings the other back" do
    kept = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget supports dark mode.")
    other = MemoryObservation.create!(memory_entity: beta, content: "SynthWidget does not support dark mode.")
    row = seed({ kind: "contradiction", observation_id_1: kept.id, observation_id_2: other.id, entity_id_1: widget.id,
                 entity_id_2: beta.id, entity_name_1: "SynthWidget", entity_name_2: "Beta Service", confidence: 0.95 }).sole

    visit review_path(view: "kind")
    wait_for_stimulus
    click_link "Review"
    within("##{ActionView::RecordIdentifier.dom_id(row)}") { click_link "Choose a side" }
    within("[data-testid='contradiction-side-1']") { click_link "Keep this" }
    within("[data-testid='review-preview-card']") do
      expect(page).to have_text("Keep ##{kept.id}: ##{other.id} marked obsolete")
      click_button "Apply"
    end

    expect(page).to have_css("[data-testid='toast-undo']")
    expect(other.reload.status).to eq("obsolete")
    within("[data-testid='toast-undo']") { click_button "Undo" }
    expect(page).to have_css(".ui-toast--notice", text: "Undone")
    expect(other.reload.status).to eq("active")
    expect(csp_console_errors).to be_empty
  end
end
