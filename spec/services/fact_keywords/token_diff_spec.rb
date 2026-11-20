# frozen_string_literal: true

require "rails_helper"

# 1.92.0: the tokens two facts differ in, and whether that is a plain value change. Every guard of
# docs/plans/done/contradiction-auto-resolve-plan.md section D answers nil here.
RSpec.describe FactKeywords::TokenDiff do
  def change(first, second) = described_class.value_change(first, second)

  describe ".value_change, key-value lines" do
    it "finds a changed port, boolean, version and number with the same unit" do
      expect(change("Port: 3000", "Port: 3001")).to eq(class: :key_value, key: "port", from: "3000", to: "3001", count: 1)
      expect(change("Enabled: false", "Enabled: true")).to include(class: :key_value, key: "enabled", from: "false", to: "true")
      expect(change("Version: v1.7.2", "Version: v1.8.0")).to include(class: :key_value, from: "v1.7.2", to: "v1.8.0")
      expect(change("Rails = 8.0", "Rails = 8.1.")).to include(class: :key_value, key: "rails", from: "8.0", to: "8.1")
      expect(change("Timeout: 5s", "Timeout: 10s")).to include(class: :key_value, from: "5s", to: "10s")
      expect(change("Size: 10 MB", "Size: 20 MB")).to include(class: :key_value, from: "10 MB", to: "20 MB")
    end

    it "compares keys without case or extra blanks" do
      expect(change("Default  Port: 3000", "default port: 3001")).to include(class: :key_value, key: "default port")
    end

    it "never pairs different keys, per-environment keys included" do
      expect(change("Port: 3000", "Timeout: 3000")).to be_nil
      expect(change("Port: 3000", "Timeout: 3001")).to be_nil
      expect(change("Port (dev): 3000", "Port (test): 3001")).to be_nil
    end

    it "refuses a changed unit" do
      expect(change("Timeout: 5s", "Timeout: 5m")).to be_nil
      expect(change("Timeout: 5s", "Timeout: 10m")).to be_nil
      expect(change("Size: 10 MB", "Size: 10 GB")).to be_nil
      expect(change("Size: 10 MB", "Size: 20 GB")).to be_nil
    end

    it "refuses list-like values, more than one value, more separators and more lines" do
      expect(change("Ports: 3000, 3001", "Ports: 3000, 3002")).to be_nil
      expect(change("Keeps: 1,000", "Keeps: 2,000")).to be_nil # a comma in the value reads as a list
      expect(change("Ports: 3000 and 3001", "Ports: 3000 and 3002")).to be_nil
      expect(change("Ports: 3000; 3001", "Ports: 3000; 3002")).to be_nil
      expect(change("Ports: 3000 | 3001", "Ports: 3000 | 3002")).to be_nil
      expect(change("Range: 3000 3001", "Range: 3000 3002")).to be_nil
      expect(change("Port: 3000\nHost: synth", "Port: 3001\nHost: synth")).to be_nil
      expect(change("Port: 3000 (was 2999)", "Port: 3001 (was 2999)")).to be_nil
    end

    it "refuses values of two kinds, a word value, a date and the same value" do
      expect(change("Enabled: true", "Enabled: 1")).to be_nil
      expect(change("Rails: 8", "Rails: 8.1")).to be_nil
      expect(change("Adapter: mysql", "Adapter: trilogy")).to be_nil
      expect(change("Released: 2026-11-12", "Released: 2026-11-13")).to be_nil
      expect(change("Port: 3000", "port: 3000.")).to be_nil
      # Boolean synonyms mean the same value (Graphy, #184).
      expect(change("Enabled: true", "Enabled: yes")).to be_nil
      expect(change("Enabled: no", "Enabled: off")).to be_nil
      expect(change("SynthFeature is enabled", "SynthFeature is on")).to be_nil
      expect(change("Enabled: yes", "Enabled: off")).to include(class: :key_value, from: "yes", to: "off")
    end
  end

  describe ".value_change, free text" do
    it "finds one or two flipped values in place" do
      expect(change("SynthService listens on port 3000", "SynthService listens on port 3001"))
        .to eq(class: :free_text, key: nil, from: "3000", to: "3001", count: 1)
      expect(change("Runs Rails 8.0 with a 5s timeout", "Runs Rails 8.1 with a 9s timeout"))
        .to include(class: :free_text, from: "8.0, 5s", to: "8.1, 9s", count: 2)
      expect(change("SynthFeature is ENABLED", "synthfeature is disabled")).to include(class: :free_text, from: "ENABLED", to: "disabled")
    end

    it "refuses three changed tokens, an inserted word, a changed word and values of two kinds" do
      expect(change("Uses 1 worker, 2 threads, 3 queues", "Uses 4 worker, 5 threads, 6 queues")).to be_nil
      expect(change("SynthFeature is supported", "SynthFeature is not supported")).to be_nil
      expect(change("Uses the mysql adapter", "Uses the trilogy adapter")).to be_nil
      expect(change("The flag is true", "The flag is 1")).to be_nil
      expect(change("A timeout of 5s", "A timeout of 5m")).to be_nil
    end

    it "refuses a value inside a list, and dated events" do
      expect(change("Listens on 3000, 3001", "Listens on 3000, 3002")).to be_nil
      expect(change("Listens on 3000 and 3001", "Listens on 3000 and 3002")).to be_nil
      expect(change("[2026-08-26] Port: 3000", "[2026-08-27] Port: 3001")).to be_nil
      expect(change("[2026-08-26] moved to port 3000", "[2026-08-26] moved to port 3001")).to be_nil
    end

    it "answers nil for blank or equal texts" do
      expect(change(nil, "Port: 3000")).to be_nil
      expect(change("Port: 3000", "Port: 3000")).to be_nil
    end
  end

  describe ".diff" do
    it "returns the differing tokens of each side with character offsets, multibyte text included" do
      found = described_class.diff("Porta è: 3000", "Porta è: 3001")

      expect(found[:left].map(&:to_h)).to eq([ { offset: 9, length: 4, text: "3000" } ])
      expect(found[:right].map(&:text)).to eq([ "3001" ])
      expect("Porta è: 3000"[9, 4]).to eq("3000")
    end

    it "handles insertions, and gives nothing for equal texts or texts too long to diff" do
      found = described_class.diff("SynthFeature is supported", "SynthFeature is not supported")
      expect([ found[:left], found[:right].map(&:text) ]).to eq([ [], [ "not" ] ])
      expect(described_class.diff("Port: 3000", "PORT: 3000")).to eq(left: [], right: [])
      long = (1..401).map { |i| "w#{i}" }.join(" ")
      expect(described_class.diff(long, "#{long} more")).to eq(left: [], right: [])
    end
  end

  it "classes values: booleans, whole numbers, dotted numbers and versions, never dates or words" do
    expect(described_class.value("Yes")).to eq(kind: :boolean, value: "yes", unit: nil)
    expect(described_class.value("10ms")).to eq(kind: :number, value: "10", unit: "ms")
    expect(described_class.value("v1.7.2")).to eq(kind: :dotted, value: "1.7.2", unit: nil)
    expect(described_class.value("2026-11-12")).to be_nil
    expect(described_class.value("utf8mb4")).to be_nil
  end
end
