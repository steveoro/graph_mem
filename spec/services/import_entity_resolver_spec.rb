# frozen_string_literal: true

require "rails_helper"

RSpec.describe ImportEntityResolver do
  let!(:project) { MemoryEntity.create!(name: "Shared Name", entity_type: "Project") }

  before do
    EntityTypeMapping.find_or_create_by!(variant: "workspace") { |mapping| mapping.canonical_type = "Project" }
  end

  it "canonicalizes imported types before exact matching" do
    expect(described_class.find_by_name_and_type("Shared Name", "workspace")).to eq(project)
  end

  it "does not fall back to an entity with the same name and another type" do
    expect(described_class.find_by_name_and_type("Shared Name", "Task")).to be_nil
  end
end
