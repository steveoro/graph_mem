# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeSetPruneJob, type: :job do
  def change_set(age_days, snapshot: { "v" => 1, "merges" => [ { "source" => { "id" => 1 } } ] })
    ChangeSet.create!(uuid: SecureRandom.uuid, kind: "merge", undo_strategy: "merge", snapshot: snapshot,
                      snapshot_bytes: snapshot.to_json.bytesize, created_at: age_days.days.ago,
                      undoable_until: (age_days - 7).days.ago)
  end

  def audit_row_for(set, age_days)
    AuditLog.create!(auditable_type: "MemoryEntity", auditable_id: 1, action: "update", changed_fields: {},
                     change_set_id: set.id, created_at: age_days.days.ago)
  end

  it "clears snapshots older than 30 days and keeps newer ones" do
    old = change_set(31)
    recent = change_set(29)

    described_class.perform_now

    expect(old.reload).to have_attributes(snapshot: nil, snapshot_bytes: nil)
    expect(recent.reload.section(:merges)).to be_present
  end

  it "deletes sets older than 90 days that no audit row references, and keeps the rest" do
    orphan = change_set(91)
    referenced = change_set(91)
    audit_row_for(referenced, 89)
    young = change_set(60)

    described_class.perform_now

    expect(ChangeSet.find_by(id: orphan.id)).to be_nil
    expect(ChangeSet.find_by(id: referenced.id)).to be_present
    expect(ChangeSet.find_by(id: young.id)).to be_present
  end

  it "keeps an undo whose original was deleted (undo_of_id becomes NULL)" do
    original = change_set(91)
    undo = ChangeSet.create!(uuid: SecureRandom.uuid, kind: "undo", undo_of: original, created_at: 80.days.ago)
    audit_row_for(undo, 80)

    described_class.perform_now

    expect(ChangeSet.find_by(id: original.id)).to be_nil
    expect(undo.reload.undo_of_id).to be_nil
  end

  it "is scheduled daily in development and production" do
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"))

    %w[development production].each do |env|
      config = recurring.dig(env, "change_set_prune")
      expect(config).to include("class" => "ChangeSetPruneJob", "queue" => "low_priority")
      expect(Fugit.parse(config["schedule"], multi: :fail)).to be_a(Fugit::Cron)
      expect(config["class"].safe_constantize).to eq(described_class)
    end
  end
end
