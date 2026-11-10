# frozen_string_literal: true

require "rails_helper"

# 1.78.0: two facts compared by their keyword paths (project › own entity › mentions).
RSpec.describe FactKeywords::Relatedness do
  def compare(first_path, second_path)
    described_class.compare_paths(first_path, first_path[1], second_path, second_path[1])
  end

  it "relates facts that share a mention, strongly when it is their first" do
    result = compare(%w[goggles_db AdminGrant User Team], %w[goggles_db AdminGrant User])

    expect(result).to have_attributes(subject: :related, strong: true, shared: %w[User])
    expect(compare(%w[goggles_db AdminGrant Team User], %w[goggles_db AdminGrant User])).to have_attributes(subject: :related, strong: false)
  end

  it "relates facts on two entities when one mentions the other's own entity" do
    expect(compare(%w[goggles_db Badge Swimmer], %w[goggles_db Swimmer Season]))
      .to have_attributes(subject: :related, shared: %w[Swimmer])
  end

  it "tells unrelated, one-sided and unknown pairs apart" do
    expect(compare(%w[goggles_db AdminGrant User], %w[goggles_db AdminGrant Team]).subject).to eq(:unrelated)
    expect(compare(%w[goggles_db AdminGrant User], %w[goggles_db AdminGrant]).subject).to eq(:one_sided)
    expect(compare(%w[goggles_db AdminGrant], %w[goggles_db AdminGrant]).subject).to eq(:unknown)
  end

  it "compares observations by their stored paths and owners" do
    root = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
    grant = MemoryEntity.create!(name: "AdminGrant", entity_type: "Model", project_id: root.id)
    first = MemoryObservation.create!(memory_entity: grant, content: "It belongs to a User.")
    second = MemoryObservation.create!(memory_entity: grant, content: "It names a Team.")
    first.update_columns(keywords: [ "Gadget Project", "AdminGrant", "User" ], keywords_at: Time.current)

    expect(described_class.computed?(first, second)).to be(false)
    second.update_columns(keywords: [ "Gadget Project", "AdminGrant", "Team" ], keywords_at: Time.current)
    expect(described_class.compare(first, second).subject).to eq(:unrelated)
  end
end
