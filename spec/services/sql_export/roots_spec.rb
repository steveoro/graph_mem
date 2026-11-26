# frozen_string_literal: true

require "rails_helper"

# The export picker's roots (moved from the retired ExportStrategy#root_nodes, 1.94.0).
RSpec.describe SqlExport::Roots do
  let!(:alpha) { MemoryEntity.create!(name: "Project Alpha", entity_type: "Project") }
  let!(:beta) { MemoryEntity.create!(name: "Project Beta", entity_type: "Project") }
  let!(:orphan) { MemoryEntity.create!(name: "Orphan Node", entity_type: "Other") }
  let!(:task_one) { fs_member!(alpha, "Task One", "Task") }
  let!(:task_two) do
    MemoryEntity.create!(name: "Task Two", entity_type: "Task").tap do |task|
      MemoryRelation.create!(from_entity: task, to_entity: task_one, relation_type: "depends_on")
    end
  end

  it "lists Projects first, then entities with no outgoing part_of or depends_on, each group by name" do
    expect(described_class.list.map(&:name)).to eq([ "Project Alpha", "Project Beta", "Orphan Node" ])
  end

  it "keeps a Project that is part of another Project" do
    nested = fs_member!(alpha, "Project Gamma", "Project")

    expect(described_class.list.map(&:id)).to include(nested.id)
  end

  it "is one query, filtered by name and capped" do
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    roots = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.list(query: "beta") }

    expect(roots.map(&:name)).to eq([ "Project Beta" ])
    expect(queries.size).to eq(1)
    expect(described_class.list(limit: 1).map(&:name)).to eq([ "Project Alpha" ])
  end

  it "treats the filter's LIKE wildcards as text" do
    expect(described_class.list(query: "%")).to be_empty
  end
end
