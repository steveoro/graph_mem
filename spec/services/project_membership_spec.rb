# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectMembership do
  let(:project_a) { MemoryEntity.create!(name: "MProjA", entity_type: "Project") }
  let(:project_b) { MemoryEntity.create!(name: "MProjB", entity_type: "Project") }

  describe ".member_ids" do
    it "skips reference_stub edges and nested Project subtrees" do
      member = MemoryEntity.create!(name: "WalkMember", entity_type: "File")
      stub = MemoryEntity.create!(name: "WalkStub", entity_type: "Class")
      nested = MemoryEntity.create!(name: "NestedProj", entity_type: "Project")
      nested_member = MemoryEntity.create!(name: "NestedMember", entity_type: "File")
      MemoryRelation.create!(from_entity: member, to_entity: project_a, relation_type: "part_of")
      MemoryRelation.create!(from_entity: stub, to_entity: project_a, relation_type: "part_of",
                             properties: { "reference_stub" => true })
      MemoryRelation.create!(from_entity: nested, to_entity: project_a, relation_type: "part_of")
      MemoryRelation.create!(from_entity: nested_member, to_entity: nested, relation_type: "part_of")

      ids = described_class.member_ids(project_a.id)
      expect(ids).to include(member.id)
      expect(ids).not_to include(stub.id)          # parked stub stays global
      expect(ids).not_to include(nested.id)       # nested Project = own scope
      expect(ids).not_to include(nested_member.id) # nested members belong to nested
    end
  end

  describe ".reassign!" do
    it "stamps the member subtree only — nested Projects and parked stubs keep their scope" do
      entity = MemoryEntity.create!(name: "MoveMe", entity_type: "File", project_id: project_a.id)
      child = MemoryEntity.create!(name: "MoveChild", entity_type: "Class", project_id: project_a.id)
      stub = MemoryEntity.create!(name: "MoveStub", entity_type: "Class")
      nested = MemoryEntity.create!(name: "MoveNested", entity_type: "Project")
      nested_member = MemoryEntity.create!(name: "MoveNestedMember", entity_type: "File",
                                           project_id: nested.id)
      MemoryRelation.create!(from_entity: entity, to_entity: project_a, relation_type: "part_of")
      MemoryRelation.create!(from_entity: child, to_entity: entity, relation_type: "part_of")
      MemoryRelation.create!(from_entity: stub, to_entity: entity, relation_type: "part_of",
                             properties: { "reference_stub" => true })
      MemoryRelation.create!(from_entity: nested, to_entity: entity, relation_type: "part_of")
      MemoryRelation.create!(from_entity: nested_member, to_entity: nested, relation_type: "part_of")

      # Move entity (and real members) under project_b
      MemoryRelation.where(from_entity: entity, relation_type: "part_of").destroy_all
      MemoryRelation.create!(from_entity: entity, to_entity: project_b, relation_type: "part_of")
      described_class.sync!(entity)

      expect(entity.reload.project_id).to eq(project_b.id)
      expect(child.reload.project_id).to eq(project_b.id)
      expect(stub.reload.project_id).to be_nil            # unclaimed stub untouched
      expect(nested.reload.project_id).to be_nil          # Projects are global
      expect(nested_member.reload.project_id).to eq(nested.id) # nested scope intact
    end
  end

  describe ".with_membership_lock" do
    it "namespaces the lock name by database" do
      conn = ActiveRecord::Base.connection
      expect(described_class.lock_name(conn)).to include(conn.current_database)
      expect(described_class.lock_name(conn)).to start_with("graph_mem.project_membership")
    end

    it "is reentrant on the same session" do
      expect do
        described_class.with_membership_lock do
          described_class.with_membership_lock { :nested }
        end
      end.not_to raise_error
    end

    it "raises LockTimeout (not Collision) when the lock cannot be acquired" do
      conn = ActiveRecord::Base.connection
      name = described_class.lock_name(conn)
      # A DIFFERENT session holds the lock (an anonymous class keeps its
      # own pool — hijacking ActiveRecord::Base.connection would make the
      # inner GET_LOCK reentrant and never time out).
      holder = stub_const("LockHolderSession",
                          Class.new(ActiveRecord::Base) { self.abstract_class = true })
      holder.establish_connection(ActiveRecord::Base.connection_db_config)
      holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(name)}, 5)")
      expect do
        described_class.with_membership_lock(timeout: 0)
      end.to raise_error(ProjectMembership::LockTimeout, /membership lock/)
    ensure
      holder.connection.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})") if holder&.connection
      holder.connection_pool&.disconnect! if holder
    end
  end
end
