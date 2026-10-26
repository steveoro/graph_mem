# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceReportRowCleanupJob, type: :job do
  it "prunes approved and dismissed rows older than the retention window" do
    AppSettings.compaction_review_row_retention_days = 30

    old_active = MaintenanceReportRow.create!(
      report_type: "compaction_review",
      row_uuid: "old-active",
      kind: "entity_merge",
      status: "active",
      signature: "entity_merge|1-2",
      payload: { "entity_a" => { "entity_id" => 1 }, "entity_b" => { "entity_id" => 2 } }
    )
    old_active.update_columns(updated_at: 31.days.ago)

    old_approved = MaintenanceReportRow.create!(
      report_type: "compaction_review",
      row_uuid: "old-approved",
      kind: "entity_merge",
      status: "approved",
      signature: "entity_merge|3-4",
      payload: { "entity_a" => { "entity_id" => 3 }, "entity_b" => { "entity_id" => 4 } }
    )
    old_approved.update_columns(updated_at: 31.days.ago)

    _recent_dismissed = MaintenanceReportRow.create!(
      report_type: "compaction_review",
      row_uuid: "recent-dismissed",
      kind: "entity_merge",
      status: "dismissed",
      signature: "entity_merge|5-6",
      payload: { "entity_a" => { "entity_id" => 5 }, "entity_b" => { "entity_id" => 6 } }
    )

    described_class.perform_now

    expect(MaintenanceReportRow.find_by(row_uuid: "old-active")).to be_present
    expect(MaintenanceReportRow.find_by(row_uuid: "old-approved")).to be_nil
    expect(MaintenanceReportRow.find_by(row_uuid: "recent-dismissed")).to be_present
  end

  it "prunes ignored rows older than the retention window" do
    AppSettings.compaction_review_row_retention_days = 30

    old_ignored = MaintenanceReportRow.create!(
      report_type: "compaction_review",
      row_uuid: "old-ignored",
      kind: "entity_merge",
      status: "ignored",
      signature: "entity_merge|7-8",
      payload: { "entity_a" => { "entity_id" => 7 }, "entity_b" => { "entity_id" => 8 } }
    )
    old_ignored.update_columns(updated_at: 31.days.ago)

    described_class.perform_now

    expect(MaintenanceReportRow.find_by(row_uuid: "old-ignored")).to be_nil
  end

  it "is scheduled daily in development and production" do
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"))

    %w[development production].each do |env|
      expect(recurring.dig(env, "maintenance_report_row_cleanup", "class")).to eq("MaintenanceReportRowCleanupJob")
      expect(recurring.dig(env, "maintenance_report_row_cleanup", "queue")).to eq("low_priority")
    end
  end
end
