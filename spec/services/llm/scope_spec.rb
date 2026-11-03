# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR2, step M: which projects a prompt touches, and the cloud gate over them.
RSpec.describe Llm::Scope do
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: gadget.id) }
  let!(:global) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Service") }

  describe ".for_entities" do
    it "maps members to their project and roots to themselves, once each" do
      expect(described_class.for_entities([ widget, gadget, widget ]).project_ids).to eq([ gadget.id ])
      expect(described_class.for_entities([ widget, alpha ]).project_ids).to contain_exactly(gadget.id, alpha.id)
    end

    it "is unscoped when any entity has no project, and names no project when empty" do
      expect(described_class.for_entities([ widget, global ])).to be_unscoped
      expect(described_class.for_entities([]).project_ids).to eq([])
    end

    it "resolves lazily and once" do
      scope = described_class.for_entities([ widget ])
      allow(widget).to receive(:project_root?).and_call_original

      2.times { scope.project_ids }

      expect(widget).to have_received(:project_root?).once
      expect(scope.inspect).to eq("#<Llm::Scope>")
    end
  end

  describe ".for_scan" do
    it "finds the Project root by name, case-insensitively, and only a root" do
      MemoryEntity.create!(name: "Beta Project", entity_type: "Component", project_id: alpha.id)

      expect(described_class.for_scan("gadget project").project_ids).to eq([ gadget.id ])
      expect(described_class.for_scan("Beta Project")).to be_unscoped
      expect(described_class.for_scan("Zq7Canary Project")).to be_unscoped
    end

    it "runs no query until asked" do
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.for_scan("Gadget Project") }
      expect(queries).to be_empty
    end
  end
end

RSpec.describe Llm::CloudGate do
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: gadget.id) }
  let!(:global) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Service") }

  def allowed?(*entities) = described_class.allowed?(Llm::Scope.for_entities(entities))

  it "is false by default, for no scope, unscoped data and no project" do
    expect(allowed?(widget)).to be(false)
    expect(described_class.allowed?(nil)).to be(false)
    gadget.update!(cloud_allowed: true)
    expect(allowed?(widget, global)).to be(false)
    expect(allowed?).to be(false)
  end

  it "is true only when every project in scope allows it, read afresh on each call" do
    gadget.update!(cloud_allowed: true)
    expect(allowed?(widget, gadget)).to be(true)
    expect(allowed?(widget, alpha)).to be(false)

    gadget.update!(cloud_root: "/path/to/gadget")
    scope = Llm::Scope.for_scan("Gadget Project", project_root: "/path/to/gadget")
    expect(described_class.allowed?(scope)).to be(true)
    gadget.update!(cloud_allowed: false)
    expect(described_class.allowed?(scope)).to be(false)
  end

  it "lets a scan out only from the project's cloud_root" do
    gadget.update!(cloud_allowed: true, cloud_root: "/path/to/gadget")

    expect(described_class.allowed?(Llm::Scope.for_scan("Gadget Project", project_root: "/path/to/other"))).to be(false)
    # The column's collation ignores case and accents; folders don't.
    %w[/path/to/Gadget /PATH/TO/GADGET /path/to/gädget].each do |variant|
      expect(described_class.allowed?(Llm::Scope.for_scan("Gadget Project", project_root: variant))).to be(false)
    end
    expect(described_class.allowed?(Llm::Scope.for_scan("Gadget Project"))).to be(false)
    gadget.update!(cloud_root: nil)
    expect(described_class.allowed?(Llm::Scope.for_scan("Gadget Project", project_root: "/path/to/gadget"))).to be(false)
  end
end
