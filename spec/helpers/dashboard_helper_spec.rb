# frozen_string_literal: true

require "rails_helper"

RSpec.describe DashboardHelper, type: :helper do
  describe "#dashboard_icon" do
    it "renders an accessible search icon" do
      html = helper.dashboard_icon(:search)

      expect(html).to include('class="dashboard-icon"')
      expect(html).to include('aria-hidden="true"')
      expect(html).to include("<svg")
    end
  end

  describe "#dashboard_topnav_icon_link" do
    it "renders a screen-reader label with a visible icon" do
      html = helper.dashboard_topnav_icon_link(
        "/search",
        icon: :search,
        label: "Search",
        testid: "topnav-search"
      )

      expect(html).to include('href="/search"')
      expect(html).to include('aria-label="Search"')
      expect(html).to include('data-testid="topnav-search"')
      expect(html).to include('class="dashboard-sr-only">Search</span>')
      expect(html).to include('class="dashboard-topnav__icon"')
    end
  end

  describe "#dashboard_stat_chip_link" do
    it "renders a linked stat chip" do
      html = helper.dashboard_stat_chip_link("Audit logs", 12, "/operator/audit_logs", id: "chip-audit-logs")

      expect(html).to include('href="/operator/audit_logs"')
      expect(html).to include('id="chip-audit-logs"')
      expect(html).to include('class="dashboard-stat-chip dashboard-stat-chip--link"')
      expect(html).to include("12")
      expect(html).to include("Audit logs")
    end
  end

  describe "#agent_context_activity_badge" do
    it "renders a localized activity badge" do
      html = helper.agent_context_activity_badge("active")

      expect(html).to include("Active")
      expect(html).to include("dashboard-badge--running")
    end
  end

  describe "#project_scan_phase_label" do
    it "humanizes known scan phases" do
      expect(helper.project_scan_phase_label("discovering_files")).to eq("Discovering files")
      expect(helper.project_scan_phase_label("reconciling_graph")).to eq("Reconciling graph")
      expect(helper.project_scan_phase_label("fallback_extraction")).to eq("Deterministic fallback")
    end

    it "falls back to humanizing unknown phases" do
      expect(helper.project_scan_phase_label("unknown_phase")).to eq("Unknown phase")
    end
  end

  describe "#project_scan_name" do
    it "prefers project_name from scan details" do
      scan = { details: { "project_name" => "graph-mem", "project_entity_name" => "GraphMem" } }

      expect(helper.project_scan_name(scan)).to eq("graph-mem")
    end

    it "falls back to project_entity_name and message" do
      expect(helper.project_scan_name({ details: { "project_entity_name" => "GraphMem" } })).to eq("GraphMem")
      expect(helper.project_scan_name({ details: {}, message: "Scan started" })).to eq("Scan started")
      expect(helper.project_scan_name({ details: {} })).to eq("—")
    end
  end
end
