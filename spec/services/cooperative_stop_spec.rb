# frozen_string_literal: true

require "rails_helper"

# 1.81.0: a stop requested for a scheduled run, checked by the jobs that loop over batches.
RSpec.describe CooperativeStop do
  include ActiveSupport::Testing::TimeHelpers

  it "is never requested outside a scheduled run" do
    expect(described_class.requested?).to be(false)
  end

  it "asks the run's check inside it, and forgets it afterwards, even after an error" do
    described_class.with(-> { true }) { expect(described_class.requested?).to be(true) }
    expect(described_class.requested?).to be(false)

    expect { described_class.with(-> { true }) { raise "boom" } }.to raise_error("boom")
    expect(described_class.requested?).to be(false)
  end

  it "restores an outer check after a nested one" do
    described_class.with(-> { false }) do
      described_class.with(-> { true }) { expect(described_class.requested?).to be(true) }
      expect(described_class.requested?).to be(false)
    end
  end

  it "asks the check at most once per INTERVAL, and remembers a stop" do
    calls = 0
    answer = false
    check = -> { calls += 1; answer }

    described_class.with(check) do
      3.times { described_class.requested? }
      expect(calls).to eq(1)

      answer = true
      # A whole second more: travel drops sub-seconds.
      travel(described_class::INTERVAL + 1.second) { expect(described_class.requested?).to be(true) }
      answer = false
      expect(described_class.requested?).to be(true)
    end
  end
end
