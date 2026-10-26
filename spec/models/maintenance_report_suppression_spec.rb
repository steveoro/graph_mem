# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceReportSuppression, type: :model do
  def suppression(signature, **attrs)
    described_class.create!(report_type: "compaction_review", signature: signature, kind: "relationship_proposal", **attrs)
  end

  it "defaults to a permanent dismissed suppression and validates the source" do
    permanent = suppression("sig-a")

    expect(permanent).to have_attributes(source: "dismissed", expires_at: nil)
    expect { suppression("sig-b", source: "forever") }.to raise_error(ActiveRecord::RecordInvalid, /Source/)
  end

  it "only suppresses while in force" do
    suppression("sig-permanent")
    suppression("sig-snoozed", source: "snoozed", expires_at: 2.days.from_now)
    suppression("sig-expired", source: "expired", expires_at: 1.minute.ago)

    expect(described_class.in_force.pluck(:signature)).to contain_exactly("sig-permanent", "sig-snoozed")
    expect(described_class.suppressed?("compaction_review", "sig-snoozed")).to be(true)
    expect(described_class.suppressed?("compaction_review", "sig-expired")).to be(false)
    expect(described_class.suppressed?("scan_review", "sig-permanent")).to be(false)
  end

  describe ".replace!" do
    it "replaces an existing suppression for the pair and returns what it deleted and created" do
      old = suppression("sig-a", source: "snoozed", expires_at: 5.days.from_now)

      deleted, created = described_class.replace!(report_type: "compaction_review", signature: "sig-a",
                                                  kind: "relationship_proposal", reason: "wrong", source: "dismissed")

      expect(deleted.map { |attrs| attrs["id"] }).to eq([ old.id ])
      expect(deleted.first).to include("source" => "snoozed")
      expect(created).to have_attributes(source: "dismissed", expires_at: nil, reason: "wrong")
      expect(described_class.where(signature: "sig-a").pluck(:id)).to eq([ created.id ])
    end

    it "just creates when the pair has none" do
      deleted, created = described_class.replace!(report_type: "compaction_review", signature: "sig-new", kind: nil,
                                                  reason: nil, source: "snoozed", expires_at: 30.days.from_now)

      expect(deleted).to eq([])
      expect(created).to be_persisted
    end
  end
  describe ".replace! (review round 1)" do
    it "keeps a permanent suppression when the new one would expire" do
      permanent = described_class.create!(report_type: "compaction_review", signature: "sig-p", source: "dismissed")

      deleted, created = described_class.replace!(report_type: "compaction_review", signature: "sig-p", kind: nil,
                                                  reason: "snooze", source: "snoozed", expires_at: 30.days.from_now)

      expect([ deleted, created ]).to eq([ [], nil ])
      expect(described_class.sole).to eq(permanent)
    end

    it "is all-or-nothing: a failed insert keeps the old suppression" do
      old = described_class.create!(report_type: "compaction_review", signature: "sig-o", source: "snoozed", expires_at: 2.days.from_now)
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique, "synthetic race")

      expect { described_class.replace!(report_type: "compaction_review", signature: "sig-o", kind: nil, reason: nil, source: "dismissed") }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect(described_class.sole).to eq(old)
    end
  end
end
