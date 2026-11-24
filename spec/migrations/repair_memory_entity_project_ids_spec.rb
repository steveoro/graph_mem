# frozen_string_literal: true

require "rails_helper"
load Rails.root.join("db/migrate/20261124120000_repair_memory_entity_project_ids.rb")

# Drift is the point of every example: the migration repairs it (membership_drift: :allowed covers
# the edge kinds it only reports, and the collision case it leaves unchanged).
RSpec.describe RepairMemoryEntityProjectIds, membership_drift: :allowed do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Project", entity_type: "Project") }
  let(:migration) { described_class.new }

  def component(name) = MemoryEntity.create!(name: name, entity_type: "Component")

  def part_of!(child, parent)
    MemoryRelation.new(from_entity: child, to_entity: parent, relation_type: "part_of").tap { |edge| edge.save!(validate: false) }
  end

  # The migration's say output and its Rails.logger lines.
  def run_up
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.formatter = ->(severity, _time, _progname, message) { "#{severity} #{message}\n" }
    Rails.logger.broadcast_to(logger)
    verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = true
    stdout = capture_stdout { migration.up }
    [ stdout, io.string ]
  ensure
    ActiveRecord::Migration.verbose = verbose
    Rails.logger.stop_broadcasting_to(logger)
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  it "repairs the drifted stamps, logs the drift before and after, and leaves the edges alone" do
    wrong = component("SynthWidget").tap { |entity| part_of!(entity, alpha).then { entity.update_column(:project_id, beta.id) } }
    stamped = component("SynthGadget").tap { |entity| entity.update_column(:project_id, alpha.id) }
    unstamped = component("SynthSprocket").tap { |entity| part_of!(entity, beta) }
    two_parents = component("SynthBolt").tap do |entity|
      part_of!(entity, alpha)
      part_of!(entity, unstamped)
      entity.update_column(:project_id, alpha.id)
    end

    stdout, log = run_up

    expect([ wrong, stamped, unstamped ].map { |entity| entity.reload.project_id }).to eq([ alpha.id, nil, beta.id ])
    expect(MemoryRelation.where(from_entity_id: two_parents.id).count).to eq(2)
    before_line = "membership drift before: wrong_project=1 stamped_without_path=1 path_without_stamp=1 " \
                  "reached_by_two_roots=1 several_parents=1"
    after_line = "membership drift after: wrong_project=0 stamped_without_path=0 path_without_stamp=0 " \
                 "reached_by_two_roots=1 several_parents=1"
    expect(stdout).to include(before_line, after_line)
    expect(log).to include("INFO [RepairMemoryEntityProjectIds] #{before_line}", "INFO [RepairMemoryEntityProjectIds] #{after_line}")
  end

  it "completes without raising and changes nothing on a global name collision" do
    stamped = component("SynthGadget").tap { |entity| entity.update_column(:project_id, alpha.id) }
    unstamped = component("SynthSprocket").tap { |entity| part_of!(entity, beta) }
    component("SynthGadget") # the global name the stamped entity would take back
    stamps = MemoryEntity.order(:id).pluck(:id, :project_id)

    stdout, log = run_up

    expect(MemoryEntity.order(:id).pluck(:id, :project_id)).to eq(stamps)
    expect([ stamped.reload.project_id, unstamped.reload.project_id ]).to eq([ alpha.id, nil ])
    expect(stdout).to include("project_id repair skipped, data unchanged", "SynthGadget", "bin/rails graph_mem:backfill_project_ids")
    expect(log).to include("WARN [RepairMemoryEntityProjectIds] project_id repair skipped, data unchanged", "SynthGadget")
    expect(stdout).to include("membership drift after: wrong_project=0 stamped_without_path=1 path_without_stamp=1")
  end

  it "has nothing to undo" do
    stamped = component("SynthGadget").tap { |entity| entity.update_column(:project_id, alpha.id) }

    migration.down

    expect(stamped.reload.project_id).to eq(alpha.id)
  end
end
