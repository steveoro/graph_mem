# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceReport, type: :model do
  describe "validations" do
    it "requires report_type to be present" do
      report = MaintenanceReport.new(report_type: nil, data: {})
      expect(report).not_to be_valid
      expect(report.errors[:report_type]).to be_present
    end

    it "only allows valid report types" do
      %w[orphans stale duplicates].each do |type|
        report = MaintenanceReport.new(report_type: type, data: { count: 0 })
        report.valid?
        expect(report.errors[:report_type]).to be_empty
      end

      report = MaintenanceReport.new(report_type: "invalid", data: {})
      expect(report).not_to be_valid
    end
  end

  describe "scopes" do
    before do
      MaintenanceReport.delete_all
    end

    describe ".recent" do
      it "orders by created_at desc" do
        old = MaintenanceReport.create!(report_type: "orphans", data: { count: 1 }, created_at: 2.days.ago)
        fresh = MaintenanceReport.create!(report_type: "orphans", data: { count: 2 })

        result = MaintenanceReport.recent
        expect(result.first).to eq(fresh)
        expect(result.last).to eq(old)
      end
    end

    describe ".by_type" do
      it "filters by report_type" do
        orphan_report = MaintenanceReport.create!(report_type: "orphans", data: { count: 0 })
        stale_report = MaintenanceReport.create!(report_type: "stale", data: { count: 5 })

        result = MaintenanceReport.by_type("orphans")
        expect(result).to include(orphan_report)
        expect(result).not_to include(stale_report)
      end
    end
  end

  describe "data serialization" do
    it "stores and retrieves JSON data with nested structures" do
      data = { count: 3, entities: [ { id: 1, name: "Foo" }, { id: 2, name: "Bar" } ] }
      report = MaintenanceReport.create!(report_type: "orphans", data: data)
      report.reload

      expect(report.data["count"]).to eq(3)
      expect(report.data["entities"].size).to eq(2)
      expect(report.data["entities"].first["name"]).to eq("Foo")
    end
  end

  describe "auto-pruning" do
    it "keeps at most MAX_REPORTS_PER_TYPE reports per type" do
      MaintenanceReport.delete_all

      (MaintenanceReport::MAX_REPORTS_PER_TYPE + 5).times do |i|
        MaintenanceReport.create!(report_type: "orphans", data: { count: i })
      end

      expect(MaintenanceReport.by_type("orphans").count).to eq(MaintenanceReport::MAX_REPORTS_PER_TYPE)
    end

    it "does not prune reports of other types" do
      MaintenanceReport.delete_all

      stale = MaintenanceReport.create!(report_type: "stale", data: { count: 99 })

      (MaintenanceReport::MAX_REPORTS_PER_TYPE + 1).times do
        MaintenanceReport.create!(report_type: "orphans", data: { count: 0 })
      end

      expect(MaintenanceReport.find_by(id: stale.id)).to be_present
    end
  end

  describe "REPORT_TYPES" do
    it "contains the expected types" do
      expect(MaintenanceReport::REPORT_TYPES).to eq(%w[orphans stale duplicates])
    end
  end
end
