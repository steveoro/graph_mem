# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReviewDigest do
  def row(priority:, group_key: "relationship_proposal|#{SecureRandom.hex(3)}", kind: "relationship_proposal", **attrs)
    MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: SecureRandom.uuid, kind: kind, status: "active",
                                 signature: "#{kind}|#{SecureRandom.hex(4)}", payload: {}, priority: priority,
                                 group_key: group_key, **attrs)
  end

  # Rows straight into the table: 1,000 ActiveRecord creates would be slow and add nothing here.
  def bulk_rows(count, priority:)
    now = Time.current
    MaintenanceReportRow.insert_all!(Array.new(count) do |i|
      { report_type: "compaction_review", row_uuid: SecureRandom.uuid, kind: "relationship_proposal", status: "active",
        signature: "bulk|#{SecureRandom.hex(6)}", payload: "{}", priority: priority, group_key: "relationship_proposal|bulk-#{i % 50}",
        created_at: now, updated_at: now }
    end)
  end

  def queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  it "ranks the top 10 groups by priority alone (a lower-priority Project root ranks below)" do
    project = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
    root = row(priority: 45, anchor_entity_id: project.id, payload: { "from_entity_type" => "Project" })
    top = row(priority: 90)
    11.times { |i| row(priority: 50 + i) }

    groups = described_class.new(threshold: 40).attention

    expect(groups.size).to eq(10)
    expect(groups.first.key).to eq(top.group_key)
    expect(groups.map(&:key)).not_to include(root.group_key)
  end

  it "counts rows and groups below the threshold, and groups at or above it" do
    row(priority: 80, group_key: "g|a")
    row(priority: 80, group_key: "g|a")
    row(priority: 10, group_key: "g|b")
    row(priority: 20, group_key: "g|c")

    digest = described_class.new(threshold: 40)

    expect(digest.attention.sole).to have_attributes(key: "g|a", count: 2)
    expect(digest.below).to eq(groups: 2, rows: 2)
    expect(digest.attention_count).to eq(1)
  end

  it "has an empty attention list (inbox zero) when nothing reaches the threshold" do
    row(priority: 5)

    expect(described_class.new(threshold: 40).attention).to be_empty
  end

  it "shows an unclassified row as its own group" do
    unclassified = row(priority: 70, group_key: nil)

    expect(described_class.new(threshold: 40).attention.sole.key).to eq("relationship_proposal|row:#{unclassified.row_uuid}")
  end

  it "keeps the query count constant from 10 to 1,000 rows" do
    bulk_rows(10, priority: 60)
    small = queries { described_class.new(threshold: 40).then { |digest| [ digest.attention, digest.below, digest.attention_count ] } }

    bulk_rows(990, priority: 60)
    large = queries { described_class.new(threshold: 40).then { |digest| [ digest.attention, digest.below, digest.attention_count ] } }

    expect(large).to eq(small)
  end
end
