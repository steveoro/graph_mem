# frozen_string_literal: true

require "rails_helper"

RSpec.describe DashboardHelper, type: :helper do
  describe "#dashboard_icon" do
    it "renders an accessible search icon" do
      html = helper.dashboard_icon(:search)

      expect(html).to include('class="ui-icon"')
      expect(html).to include('aria-hidden="true"')
      expect(html).to include("<svg")
    end
  end

  describe "#agent_context_activity_badge" do
    it "renders a localized activity badge" do
      html = helper.agent_context_activity_badge("active")

      expect(html).to include("Active")
      expect(html).to include("ui-badge--running")
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
end
