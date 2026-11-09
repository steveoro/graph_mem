# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# 1.75.0: a Rails code map written into a project as its skeleton.
RSpec.describe ProjectScanner::SkeletonWriter do
  let(:root) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let(:source) { RailsCodeMap::SOURCE }

  def build_map(extra = {})
    Dir.mktmpdir("skeleton") do |dir|
      RailsCodeMap.build(write_rails_code_map_tree(dir, extra), reserved_names: [ "Gadget" ])
    end
  end

  def write(map, scan_id: "scan-1")
    described_class.new(map: map, root: root, scan_id: scan_id).call
  end

  def entity(name) = MemoryEntity.find_by!(name: name, project_id: root.id)

  it "creates every entry under the root with its type, aliases, facts and relations" do
    writer = write(build_map)

    badge = entity("Gadget::Badge")
    expect(writer.errors).to be_empty
    expect(badge).to have_attributes(entity_type: "Model", aliases: "Badge,gadget/badge", description: nil)
    expect(badge.memory_observations.pluck(:content, :source, :confidence, :perspective))
      .to eq([ [ "Defined at app/models/gadget/badge.rb:L2", source, 1.0, "world" ] ])
    expect(MemoryRelation.exists?(from_entity_id: badge.id, to_entity_id: root.id, relation_type: "part_of")).to be(true)
    expect(MemoryRelation.find_by!(from_entity_id: badge.id, to_entity_id: entity("Gadget::Swimmer").id, relation_type: "belongs_to")
                         .properties).to include("source" => source, "scan_id" => "scan-1")
    expect(entity("app/views/gadget/swimmers").entity_type).to eq("View")
    # 15 Defined at / Templates facts, plus the controller's Routes fact.
    expect(writer.counts).to include(entities_created: 15, observations_created: 16)
    expect(writer.created_ids.size).to eq(15)
  end

  it "creates nothing on a second run" do
    map = build_map
    write(map)

    writer = write(map, scan_id: "scan-2")

    expect(writer.counts.values).to all(eq(0))
    expect(writer.review_items).to be_empty
    expect(writer.entities.size).to eq(15)
  end

  it "upgrades a stored Class to the role type, keeps another role, and keeps an existing parent" do
    file = MemoryEntity.create!(name: "app/models/gadget/swimmer.rb", entity_type: "File", project_id: root.id)
    swimmer = MemoryEntity.create!(name: "Gadget::Swimmer", entity_type: "Class", project_id: root.id)
    MemoryRelation.create!(from_entity_id: swimmer.id, to_entity_id: file.id, relation_type: "part_of")
    badge = MemoryEntity.create!(name: "Gadget::Badge", entity_type: "Service", project_id: root.id, aliases: "badge")

    write(build_map)

    expect(swimmer.reload.entity_type).to eq("Model")
    expect(MemoryRelation.where(from_entity_id: swimmer.id, relation_type: "part_of").pluck(:to_entity_id)).to eq([ file.id ])
    expect(badge.reload).to have_attributes(entity_type: "Service", aliases: "badge,gadget/badge")
  end

  it "supersedes a Defined at whose line moved and obsoletes an own fact the entry lost" do
    write(build_map)
    badge = entity("Gadget::Badge")
    stale = MemoryObservation.create!(memory_entity: badge, content: "Routes: GET /badges", source: source)

    write(build_map("app/models/gadget/badge.rb" => "# Badges.\nmodule Gadget\n  class Badge < ApplicationRecord\n  end\nend\n"))

    active = badge.memory_observations.active.pluck(:content)
    expect(active).to eq([ "Defined at app/models/gadget/badge.rb:L3" ])
    expect(badge.memory_observations.find_by(content: "Defined at app/models/gadget/badge.rb:L2").status).to eq("superseded")
    expect(stale.reload.status).to eq("obsolete")
  end

  it "skips a fact another source already holds, and leaves other sources alone" do
    root
    swimmer = MemoryEntity.create!(name: "Gadget::Swimmer", entity_type: "Model", project_id: root.id)
    imported = MemoryObservation.create!(memory_entity: swimmer, content: "Defined at app/models/gadget/swimmer.rb:L2",
                                         source: "rails_ast_extractor")

    write(build_map)

    expect(swimmer.memory_observations.active.pluck(:id)).to eq([ imported.id ])
  end

  it "retires a gone entity's facts and queues a gone relation for review" do
    write(build_map)
    job = entity("Gadget::RenderJob")
    belongs = MemoryRelation.find_by!(from_entity_id: entity("Gadget::Badge").id, relation_type: "belongs_to")

    writer = write(build_map("app/jobs/gadget/render_job.rb" => nil,
                             "app/models/gadget/badge.rb" => "module Gadget\n  class Badge < ApplicationRecord\n    include Gadget::Trackable\n  end\nend\n"))

    expect(job.memory_observations.active).to be_empty
    expect(writer.review_items).to contain_exactly(hash_including(kind: "delete_relation", relation_id: belongs.id))
    expect(MemoryRelation.exists?(belongs.id)).to be(true)
  end

  it "retires nothing when the map is incomplete, or for an entity whose file was unreadable" do
    write(build_map)
    job = entity("Gadget::RenderJob")

    stub_const("RailsCodeMap::MAX_FILES", 5)
    writer = write(build_map)
    expect(writer.review_items).to be_empty
    expect(job.memory_observations.active.count).to eq(1)

    stub_const("RailsCodeMap::MAX_FILES", 3000)
    write(build_map("app/jobs/gadget/render_job.rb" => "module Gadget\n  class RenderJob <\n"))
    expect(job.memory_observations.active.count).to eq(1)
  end

  it "reports an entry that fails and still writes the others" do
    allow(MemoryEntity).to receive(:create!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::RecordInvalid, MemoryEntity.new if attributes[:name] == "Gadget::RenderJob"

      original.call(**attributes)
    end

    writer = write(build_map)

    expect(writer.errors.sole).to start_with("Code map: failed to write Gadget::RenderJob")
    expect(MemoryEntity.where(project_id: root.id).count).to eq(14)
  end

  it "retires nothing in a run where an entry failed, and doesn't count the rolled-back create" do
    write(build_map)
    job = entity("Gadget::RenderJob")
    allow(MemoryEntity).to receive(:find_by).and_wrap_original do |original, **attributes|
      raise ActiveRecord::StatementInvalid, "synthetic failure" if attributes[:name] == "Gadget::RenderJob"

      original.call(**attributes)
    end

    writer = write(build_map("app/models/gadget/badge.rb" => "module Gadget\n  class Badge < ApplicationRecord\n  end\nend\n"))

    expect(writer.errors.sole).to start_with("Code map: failed to write Gadget::RenderJob")
    expect(job.memory_observations.active.count).to eq(1)
    expect(writer.review_items).to be_empty
  end

  it "keeps a rolled-back create out of the counts and the created ids" do
    allow(MemoryObservation).to receive(:create!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::RecordInvalid, MemoryObservation.new if attributes[:content].to_s.include?("render_job.rb")

      original.call(**attributes)
    end

    writer = write(build_map)

    expect(writer.errors.sole).to start_with("Code map: failed to write Gadget::RenderJob")
    expect(MemoryEntity.where(name: "Gadget::RenderJob")).to be_empty
    expect(writer.counts).to include(entities_created: 14)
    expect(writer.created_ids.size).to eq(14)
  end
end
