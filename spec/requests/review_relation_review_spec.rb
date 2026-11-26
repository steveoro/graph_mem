# frozen_string_literal: true

require "rails_helper"

# Dream State R1c: the Review card of an informational relation_review row: Dismiss and Snooze only.
RSpec.describe "Review & Fix › relation_review", type: :request do
  let!(:project) { fs_project!("SynthApp") }
  let!(:library) { MemoryEntity.create!(name: "SynthLib", entity_type: "Gem") }
  let!(:uses) { MemoryRelation.create!(from_entity: project, to_entity: library, relation_type: "depends_on") }
  let!(:fact) { fs_observe!(project, "SynthApp migrated away from SynthLib in 2.0.") }
  let!(:row) do
    item = CompactionReviewApplier::RelationReview.item(RemovalEvidence.edges(after_id: 0, limit: 10).sole, fact)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole
  end
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html" } }

  before { sign_in_operator }

  it "shows the relation, the fact and the informational note, with Dismiss and Snooze but no Apply" do
    get review_row_path(row.row_uuid)

    expect(response).to have_http_status(:ok)
    card = Nokogiri::HTML5.fragment(response.body)
    expect(card.at_css("[data-testid='relation-review-summary']").text.squish)
      .to eq("Relation ##{uses.id}: 'SynthApp' depends_on 'SynthLib'. A fact of SynthApp says 'SynthLib' was removed, replaced or dropped.")
    expect(card.css("[data-testid='relation-review-evidence'] li").map { |li| li.text.squish })
      .to eq([ "##{fact.id} on SynthApp: SynthApp migrated away from SynthLib in 2.0." ])
    expect(card.at_css("[data-testid='relation-review-informational']").text).to start_with("Informational: nothing is applied.")
    expect(response.body).to include("SynthApp depends_on SynthLib: removal fact ##{fact.id}")
    expect(card.css("a, button, input[type=submit]").map { |node| node.text.presence || node["value"] }.compact.map(&:squish))
      .to include("Dismiss", "Snooze 30 days").and(satisfy { |labels| labels.none? { |label| label.start_with?("Apply") } })
    expect(card.at_css("[data-testid='review-effects']")).to be_nil
  end

  it "answers the validation error to a posted apply, and keeps the row" do
    post review_row_apply_path(row.row_uuid), headers: turbo

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("ending a relation arrives with the relation lifecycle; remove the relation by hand if it is wrong")
    expect(row.reload.status).to eq("active")
  end

  it "dismisses it" do
    post review_row_dismiss_path(row.row_uuid), headers: turbo

    expect(response).to have_http_status(:ok)
    expect(row.reload.status).to eq("dismissed")
  end
end
