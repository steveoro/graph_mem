# frozen_string_literal: true

require "rails_helper"

# R1a: the Background jobs card polls its unmapped count; it is cached for a minute, and a mapping
# decision or a finished sweep expires it. The test environment uses a null store, so a memory
# store stands in for Rails.cache here.
RSpec.describe UnmappedRelationTypes, ".cached_count" do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:suffix) { SecureRandom.hex(3) }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def stored_relation(type)
    from = MemoryEntity.create!(name: "SynthService #{suffix} #{type}", entity_type: "Service")
    to = MemoryEntity.create!(name: "SynthWidget #{suffix} #{type}", entity_type: "Component")
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder_#{SecureRandom.hex(4)}")
    relation.update_column(:relation_type, type)
    relation
  end

  def card_count = MaintenanceDashboardSnapshot.new.relation_types_snapshot[:unmapped_count]

  it "doesn't re-query within the window, while the page's count stays exact" do
    stored_relation("synth_links_to")
    expect(card_count).to eq(1)

    allow(described_class).to receive(:count).and_call_original
    stored_relation("synth_feeds")

    expect(card_count).to eq(1)
    expect(described_class).not_to have_received(:count)
    expect(described_class.call.map(&:type)).to contain_exactly("synth_links_to", "synth_feeds")
  end

  it "is refreshed by map, accept, remove and a finished sweep" do
    stored_relation("synth_links_to")
    stored_relation("synth_feeds")
    expect(card_count).to eq(2)

    RelationTypeDecision.map("synth_links_to", "depends_on")
    expect(card_count).to eq(1)

    result = RelationTypeDecision.accept("synth_feeds")
    expect(card_count).to eq(0)

    RelationTypeDecision.remove(RelationTypeMapping.find_by!(variant: result.type).id)
    expect(card_count).to eq(1)

    stored_relation("synth_pings")
    expect(card_count).to eq(1)
    RelationTypeSweep.call(dry_run: true)
    expect(card_count).to eq(1)
    RelationTypeSweep.call
    expect(card_count).to eq(2)
  end
end
