# frozen_string_literal: true

require "rails_helper"

# 1.84.0: how far the current step of a scheduled run is, reported by the jobs that loop over batches.
RSpec.describe StepProgress do
  it "does nothing outside a scheduled run" do
    expect { described_class.report(done: 1, total: 2) }.not_to raise_error
    expect(described_class.active?).to be(false)
  end

  it "hands each report to the run's sink, and forgets it afterwards, even after an error" do
    reports = []
    described_class.with(->(**report) { reports << report }) do
      expect(described_class.active?).to be(true)
      described_class.report(done: 3, total: 10, label: "Paths")
    end

    expect(reports).to eq([ { done: 3, total: 10, label: "Paths" } ])
    expect { described_class.with(->(**) { }) { raise "boom" } }.to raise_error("boom")
    expect(described_class.active?).to be(false)
  end

  it "never lets a failing sink fail the step" do
    described_class.with(->(**) { raise ActiveRecord::StatementInvalid, "locked" }) do
      expect { described_class.report(done: 1, total: 2) }.not_to raise_error
    end
  end
end
