# frozen_string_literal: true

require "rails_helper"

RSpec.describe UiHelper, type: :helper do
  # operator_signed_in? is a controller helper_method, absent from the helper test view.
  def stub_role(operator:)
    helper.define_singleton_method(:operator_signed_in?) { operator }
  end

  def visit_path(path)
    allow(helper).to receive(:request).and_return(
      ActionDispatch::TestRequest.create("PATH_INFO" => path, "REQUEST_METHOD" => "GET")
    )
  end

  describe "#can_write?" do
    it "is true for the operator" do
      stub_role(operator: true)
      expect(helper.can_write?).to be true
    end

    it "is false when signed out" do
      stub_role(operator: false)
      expect(helper.can_write?).to be false
    end
  end

  describe "#ui_nav_link" do
    it "marks only the current path with aria-current" do
      visit_path("/search")

      current = Nokogiri::HTML.fragment(helper.ui_nav_link("Search", "/search", testid: "nav-search")).at_css("a")
      other = Nokogiri::HTML.fragment(helper.ui_nav_link("Explore", "/graph", testid: "nav-explore")).at_css("a")

      expect(current["aria-current"]).to eq("page")
      expect(current["data-testid"]).to eq("nav-search")
      expect(other["aria-current"]).to be_nil
    end

    it "lets the caller override the current state" do
      visit_path("/search")

      link = Nokogiri::HTML.fragment(helper.ui_nav_link("Search", "/search", testid: "nav-search", current: false)).at_css("a")

      expect(link["aria-current"]).to be_nil
    end

    it "escapes the label and renders the icon and a positive badge" do
      visit_path("/")

      html = helper.ui_nav_link("<b>SynthWidget</b>", "/graph", testid: "nav-explore", icon: :search, badge: 3)

      expect(html).to include("&lt;b&gt;SynthWidget&lt;/b&gt;")
      expect(html).to include("<svg")
      expect(Nokogiri::HTML.fragment(html).at_css("[data-testid='nav-explore-badge']").text).to eq("3")
    end

    it "merges extra data attributes" do
      visit_path("/")

      link = Nokogiri::HTML.fragment(helper.ui_nav_link("Jobs", "/operator/jobs", testid: "nav-jobs", data: { turbo: false })).at_css("a")

      expect(link["data-turbo"]).to eq("false")
      expect(link["data-testid"]).to eq("nav-jobs")
    end

    it "renders no badge for 0" do
      visit_path("/")

      expect(helper.ui_nav_link("Review", "/r", testid: "nav-review", badge: 0)).not_to include("nav-review-badge")
    end
  end

  describe "#ui_page_header" do
    it "renders one h1, the subtitle and the actions" do
      html = helper.ui_page_header("Alpha Service", subtitle: "Synthetic") { helper.tag.a("Act", href: "/x") }
      doc = Nokogiri::HTML.fragment(html)

      expect(doc.css("h1").map(&:text)).to eq([ "Alpha Service" ])
      expect(doc.at_css(".ui-page-header__subtitle").text).to eq("Synthetic")
      expect(doc.at_css(".ui-page-header__actions a")["href"]).to eq("/x")
    end
  end

  describe "#ui_review_backlog_count" do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(cache) }

    def create_row(uuid, status)
      MaintenanceReportRow.create!(
        report_type: "compaction_review", row_uuid: uuid, kind: "entity_merge", status: status,
        signature: "entity_merge|#{uuid}", payload: { "entity_a" => { "entity_id" => 1 }, "entity_b" => { "entity_id" => 2 } }
      )
    end

    it "counts active rows and caches the count" do
      stub_role(operator: true)
      create_row("active-1", "active")
      create_row("dismissed-1", "dismissed")

      expect(helper.ui_review_backlog_count).to eq(1)
      create_row("active-2", "active")
      expect(helper.ui_review_backlog_count).to eq(1)
    end

    it "is 0 without querying when the visitor can't write" do
      stub_role(operator: false)
      expect(MaintenanceReportRow).not_to receive(:active)

      expect(helper.ui_review_backlog_count).to eq(0)
    end
  end
end
