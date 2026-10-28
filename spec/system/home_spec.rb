# frozen_string_literal: true

require "rails_helper"

# UI-2b: Home in a browser (synthetic data): the lazy widgets load, the digest's "Open" lands on
# the same group on /review, and `/` focuses the quick search.
RSpec.describe "Home", type: :system do
  include ReviewHelper

  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }

  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    allow(AppSettings).to receive(:review_number).and_call_original
    allow(AppSettings).to receive(:review_number).with(:review_attention_threshold).and_return(1)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [
      { id: SecureRandom.uuid, kind: "relationship_proposal", from_entity_id: widget.id, to_entity_id: beta.id,
        relation_type: "depends_on", confidence_band: "high", score: 14 }
    ])
    sign_in_through_form
    expect(page).to have_css("nav.ui-sidebar")
  end

  # Lazy frames load once they're in view; scroll to them so the spec doesn't depend on the layout
  # (CI runs without the built Tailwind CSS, where the page is much longer).
  def show_frame(id)
    scroll_to(find("turbo-frame##{id}"))
  end

  it "goes from the digest to the same group on Review" do
    visit root_path

    show_frame("home-health")
    expect(page).to have_css("[data-testid='home-pill-database'][data-status='ok']")
    expect(page).to have_css("[data-testid='home-pill-embeddings'][data-status='danger']", text: "unreachable")
    show_frame("home-digest")
    within("turbo-frame#home-digest") do
      expect(page).to have_css("[data-testid='home-digest-row']", text: "SynthWidget")
      click_link "Open"
    end

    anchor = review_group_dom_id(MaintenanceReportRow.active.sole.group_key)
    expect(page).to have_current_path(review_path)
    expect(page).to have_css("##{anchor}[data-testid='review-group']", text: "SynthWidget")
    expect(page.evaluate_script("window.location.hash")).to eq("##{anchor}")
    expect(csp_console_errors).to be_empty
  end

  it "focuses the quick search on / and searches from it" do
    visit root_path
    wait_for_stimulus
    show_frame("home-health")
    expect(page).to have_css("turbo-frame#home-health [data-testid='home-health']")

    # Selenium's synthetic keys don't reach the window listener in headless Chrome; dispatch the
    # same keydown a real "/" produces.
    focus_on_slash = "window.dispatchEvent(new KeyboardEvent('keydown', { key: '/', bubbles: true, cancelable: true }))"
    page.execute_script(focus_on_slash)
    expect(page.evaluate_script("document.activeElement.id")).to eq("home-search-q")
    find_by_id("home-search-q").send_keys("a/b")
    expect(find_by_id("home-search-q").value).to eq("a/b") # a "/" typed into the box stays text
    fill_in "home-search-q", with: "SynthWidget"
    click_button "Search"

    expect(page).to have_current_path(search_path(q: "SynthWidget"))
    expect(page).to have_text("SynthWidget")
  end
end
