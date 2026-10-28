# frozen_string_literal: true

require "rails_helper"

# UI-3 F1: the search filter's validation, normalisation and entity scope. Synthetic data only.
RSpec.describe SearchFilter do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:gadget) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id) }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service", project_id: gadget.id) }
  let!(:stray) { MemoryEntity.create!(name: "Stray Note", entity_type: "Component") }

  describe ".build" do
    it "is the default, frozen filter when nothing is passed" do
      filter = described_class.build

      expect(filter).to be_default.and be_frozen
      expect(filter.entity_scope).to be_nil
      expect(filter.fields).to eq(%i[name entity_type aliases observations])
      expect(filter.diagnostic).to be_nil
    end

    it "treats explicit defaults and an empty type list as omitted" do
      filter = described_class.build(entity_types: [], search_in_name: true, search_in_type: true,
                                     search_in_aliases: true, search_in_observations: true)

      expect(filter).to be_default
    end

    it "accepts a Project root id as an integer or a numeric string" do
      expect(described_class.build(project_id: alpha.id).project_id).to eq(alpha.id)
      expect(described_class.build(project_id: alpha.id.to_s).project_id).to eq(alpha.id)
    end

    [ 0, -1, "abc", "1.5", 999_999_999 ].each do |project_id|
      it "refuses project_id #{project_id.inspect}" do
        expect { described_class.build(project_id: project_id) }
          .to raise_error(GraphMem::InvalidArgumentsError, "project_id must be the id of a Project entity.")
      end
    end

    it "refuses an entity that isn't a Project root" do
      nested = MemoryEntity.create!(name: "Nested Project", entity_type: "Project", project_id: alpha.id)

      [ widget.id, nested.id ].each do |project_id|
        expect { described_class.build(project_id: project_id) }
          .to raise_error(GraphMem::InvalidArgumentsError, "project_id must be the id of a Project entity.")
      end
    end

    it "strips and de-duplicates entity types case-insensitively" do
      filter = described_class.build(entity_types: [ " Component ", "component", "Service" ])

      expect(filter.entity_types).to eq(%w[Component Service])
      expect(filter).not_to be_default
    end

    [ [ " " ], [ "" ], [ "x" * 101 ], Array.new(21) { |i| "Type#{i}" }, "Component", [ 1 ] ].each do |types|
      it "refuses entity_types #{types.inspect.truncate(40)}" do
        expect { described_class.build(entity_types: types) }
          .to raise_error(GraphMem::InvalidArgumentsError, "entity_types must be a list of 1 to 20 non-blank entity types.")
      end
    end

    it "accepts 20 types of up to 100 characters" do
      types = Array.new(19) { |i| "Type#{i}" } + [ "x" * 100 ]

      expect(described_class.build(entity_types: types).entity_types.size).to eq(20)
    end

    it "refuses all four search fields off" do
      expect {
        described_class.build(search_in_name: false, search_in_type: false, search_in_aliases: false, search_in_observations: false)
      }.to raise_error(GraphMem::InvalidArgumentsError, "At least one search field (name, type, aliases, observations) must be enabled.")
    end

    it "maps the search_in_* flags to fields" do
      filter = described_class.build(search_in_type: false, search_in_observations: false)

      expect(filter.fields).to eq(%i[name aliases])
      expect(filter.text_fields).to eq(%i[name aliases])
      expect(filter).to be_entity_text
      expect(filter).not_to be_observations
      expect(filter.entity_scope).to be_nil

      only_observations = described_class.build(search_in_name: false, search_in_type: false, search_in_aliases: false)
      expect(only_observations).not_to be_entity_text
      expect(only_observations).to be_observations
    end
  end

  describe "#entity_scope" do
    it "matches the Project root and its members only" do
      expect(described_class.build(project_id: alpha.id).entity_scope).to contain_exactly(alpha, widget)
    end

    it "matches types exactly and case-insensitively; an unknown type matches nothing" do
      expect(described_class.build(entity_types: [ "component" ]).entity_scope).to contain_exactly(widget, stray)
      expect(described_class.build(entity_types: [ "Compo" ]).entity_scope).to be_empty
    end

    it "combines project and types" do
      filter = described_class.build(project_id: gadget.id, entity_types: %w[Service Project])

      expect(filter.entity_scope).to contain_exactly(gadget, router)
    end
  end

  describe "#diagnostic" do
    it "describes a narrowing filter for retrieval.filters" do
      filter = described_class.build(project_id: alpha.id, entity_types: [ "Component" ], search_in_aliases: false)

      expect(filter.diagnostic).to eq(project_id: alpha.id, entity_types: [ "Component" ], search_in: %w[name type observations])
    end
  end
end
