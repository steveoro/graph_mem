# frozen_string_literal: true

require "rails_helper"

# The one "expected membership / drift" implementation (ProjectIdBackfill#drift), used by the
# backfill's report, the repair migration and the spec suite's drift guard.
RSpec.describe ProjectIdBackfill, "drift" do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Project", entity_type: "Project") }

  def component(name) = MemoryEntity.create!(name: name, entity_type: "Component")

  def part_of!(child, parent, type: "part_of")
    MemoryRelation.new(from_entity: child, to_entity: parent, relation_type: type).tap { |edge| edge.save!(validate: false) }
  end

  it "reports nothing on a consistent graph" do
    widget = component("SynthWidget")
    part_of!(widget, alpha)
    ProjectMembership.sync!(widget)

    drift = described_class.drift

    expect(drift.any?).to be(false)
    expect(drift.summary).to eq("wrong_project=0 stamped_without_path=0 path_without_stamp=0 reached_by_two_roots=0 several_parents=0")
  end

  # Drift is the point of every example below.
  context "with one case of each kind", membership_drift: :allowed do
    let!(:wrong) { component("SynthWidget").tap { |entity| part_of!(entity, alpha).then { entity.update_column(:project_id, beta.id) } } }
    let!(:stamped) { component("SynthGadget").tap { |entity| entity.update_column(:project_id, alpha.id) } }
    let!(:unstamped) { component("SynthSprocket").tap { |entity| part_of!(entity, alpha) } }
    let!(:two_roots) do
      component("SynthBolt").tap do |entity|
        part_of!(entity, alpha)
        part_of!(entity, beta, type: "Part_Of") # the column's collation reads it as part_of
        entity.update_column(:project_id, alpha.id)
      end
    end

    it "counts and lists each kind" do
      drift = described_class.drift

      expect(drift.counts).to eq(wrong_project: 1, stamped_without_path: 1, path_without_stamp: 1, reached_by_two_roots: 1, several_parents: 1)
      expect(drift.ids).to eq(wrong_project: [ wrong.id ], stamped_without_path: [ stamped.id ], path_without_stamp: [ unstamped.id ],
                              reached_by_two_roots: [ two_roots.id ], several_parents: [ two_roots.id ])
      expect(drift.any?).to be(true)
    end

    it "prints the drift counts in the dry run, and writes nothing" do
      lines = []
      stamps = MemoryEntity.order(:id).pluck(:id, :project_id)

      report = described_class.new(out: ->(line) { lines << line }).run(dry_run: true)

      expect(lines).to include("  drift before the run: wrong_project=1 stamped_without_path=1 path_without_stamp=1 " \
                               "reached_by_two_roots=1 several_parents=1", "  (no rows written)")
      expect(report.drift.counts[:wrong_project]).to eq(1)
      expect(MemoryEntity.order(:id).pluck(:id, :project_id)).to eq(stamps)
    end

    it "repairs the stamps when applied and leaves the edges to the operator" do
      described_class.new(out: ->(_line) { }).run

      expect(described_class.drift.counts).to eq(wrong_project: 0, stamped_without_path: 0, path_without_stamp: 0,
                                                 reached_by_two_roots: 1, several_parents: 1)
      expect([ wrong.reload.project_id, stamped.reload.project_id, unstamped.reload.project_id ]).to eq([ alpha.id, nil, alpha.id ])
    end
  end
end
