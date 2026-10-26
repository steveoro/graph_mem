# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceReportRow, type: :model do
  def row(status:, **attrs)
    described_class.create!(report_type: "compaction_review", row_uuid: SecureRandom.uuid, kind: "relationship_proposal",
                            signature: "sig-#{SecureRandom.hex(4)}", payload: {}, status: status, **attrs)
  end

  it "accepts the expired status and counts it as resolved" do
    expired = row(status: "expired")

    expect(expired).to be_expired
    expect(expired).to be_resolved
    expect(row(status: "ignored")).not_to be_resolved
  end

  it "scopes resolved, expired, snoozed, attention, group and project" do
    approved = row(status: "approved")
    expired = row(status: "expired")
    snoozed = row(status: "ignored", expires_at: 3.days.from_now)
    legacy_ignored = row(status: "ignored")
    urgent = row(status: "active", priority: 80, group_key: "relationship_proposal|1-2", project_id: 7)
    calm = row(status: "active", priority: 10)

    expect(described_class.resolved).to contain_exactly(approved, expired)
    expect(described_class.expired).to eq([ expired ])
    expect(described_class.snoozed).to eq([ snoozed ])
    expect(described_class.snoozed).not_to include(legacy_ignored)
    expect(described_class.attention(40)).to eq([ urgent ])
    expect(described_class.attention(10)).to contain_exactly(urgent, calm)
    expect(described_class.by_group("relationship_proposal|1-2")).to eq([ urgent ])
    expect(described_class.by_project(7)).to eq([ urgent ])
  end

  it "accepts the known resolvers, policy:<name> included, and refuses others" do
    %w[operator agent generator policy:dangling].each do |resolver|
      expect(row(status: "dismissed", resolved_by: resolver)).to be_persisted
    end
    expect { row(status: "dismissed", resolved_by: "somebody") }.to raise_error(ActiveRecord::RecordInvalid, /Resolved by/)
  end
end
