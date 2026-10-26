# frozen_string_literal: true

require "rails_helper"
require "fugit"

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
      config = recurring.dig(env, "maintenance_report_row_cleanup")
      expect(config).to include("class" => "MaintenanceReportRowCleanupJob", "queue" => "low_priority")
      # Same parse as SolidQueue::RecurringTask#ensure_schedule_supported (the test DB has no
      # solid_queue tables, so the task model itself can't be built here).
      expect(Fugit.parse(config["schedule"], multi: :fail)).to be_a(Fugit::Cron)
      expect(config["class"].safe_constantize).to eq(described_class)
    end
  end

  it "falls back to 30 days when retention is 0" do
    AppSettings.compaction_review_row_retention_days = 0

    { "dismissed-29d" => 29, "dismissed-31d" => 31 }.each_with_index do |(uuid, age), i|
      MaintenanceReportRow.create!(
        report_type: "compaction_review",
        row_uuid: uuid,
        kind: "entity_merge",
        status: "dismissed",
        signature: "entity_merge|#{20 + i}-#{30 + i}",
        payload: { "entity_a" => { "entity_id" => 20 + i }, "entity_b" => { "entity_id" => 30 + i } }
      ).update_columns(updated_at: age.days.ago)
    end

    described_class.perform_now

    expect(MaintenanceReportRow.find_by(row_uuid: "dismissed-29d")).to be_present
    expect(MaintenanceReportRow.find_by(row_uuid: "dismissed-31d")).to be_nil
  ensure
    AppSettings.compaction_review_row_retention_days = 30
  end
  describe "UI-5a" do
    def old_row(uuid, status, **attrs)
      MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: uuid, kind: "relationship_proposal",
                                   status: status, signature: "sig-#{uuid}", payload: {}, **attrs)
                          .tap { |row| row.update_columns(updated_at: 31.days.ago) }
    end

    it "prunes old expired rows but keeps a snoozed row until its snooze ends" do
      old_row("old-expired", "expired")
      old_row("old-snoozed", "ignored", expires_at: 5.days.from_now)
      old_row("old-snooze-over", "ignored", expires_at: 1.day.ago)

      described_class.perform_now

      expect(MaintenanceReportRow.pluck(:row_uuid)).to eq([ "old-snoozed" ])
    end

    it "deletes suppressions that expired more than the retention window ago" do
      suppression = ->(signature, expires_at) do
        MaintenanceReportSuppression.create!(report_type: "compaction_review", signature: signature, source: "expired", expires_at: expires_at)
      end
      suppression.call("long-gone", 31.days.ago)
      suppression.call("recently-expired", 2.days.ago)
      suppression.call("in-force", 10.days.from_now)
      MaintenanceReportSuppression.create!(report_type: "compaction_review", signature: "permanent")

      described_class.perform_now

      expect(MaintenanceReportSuppression.pluck(:signature)).to contain_exactly("recently-expired", "in-force", "permanent")
    end
  end
end
