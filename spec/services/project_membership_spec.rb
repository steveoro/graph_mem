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

  describe "lock ordering (advisory lock BEFORE the transaction)" do
    # Catches P7/P10/P18-style regressions: a membership writer that takes
    # GET_LOCK *inside* its transaction deadlocks against the backfill.
    # The spec observes GET_LOCK via sql.active_record and asserts the
    # session had NOT opened a transaction yet.
    # The spec's transactional fixture already holds one transaction open,
    # so the assertion is "GET_LOCK ran at the BASELINE depth" — any
    # service-level transaction wrapping it bumps the count above that.
    def open_transactions_at_get_lock
      baseline = ActiveRecord::Base.connection.open_transactions
      count = nil
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        count ||= ActiveRecord::Base.connection.open_transactions if payload[:sql].to_s.include?("GET_LOCK")
      end
      yield
      count - baseline
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "GraphWriteService.call takes GET_LOCK outside its transaction" do
      project = MemoryEntity.create!(name: "LockOrdProj", entity_type: "Project")
      node = MemoryEntity.create!(name: "LockOrdNode", entity_type: "Class")

      excess = open_transactions_at_get_lock do
        GraphWriteService.call(operations: [
          { type: "create_relation", from_entity_id: node.id, to_entity_id: project.id, relation_type: "part_of" }
        ])
      end
      expect(excess).to eq(0)
    end

    it "GraphDeleteService.call takes GET_LOCK outside its transaction" do
      from_entity = MemoryEntity.create!(name: "LockOrdDelFrom", entity_type: "Class")
      to_entity = MemoryEntity.create!(name: "LockOrdDelTo", entity_type: "Class")
      edge = MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity, relation_type: "part_of")

      excess = open_transactions_at_get_lock do
        GraphDeleteService.call(operations: [ { type: "delete_relation", relation_id: edge.id } ])
      end
      expect(excess).to eq(0)
    end

    it "GraphDeleteService.execute_one wraps the op in lock+transaction" do
      from_entity = MemoryEntity.create!(name: "LockOrdExFrom", entity_type: "Class")
      to_entity = MemoryEntity.create!(name: "LockOrdExTo", entity_type: "Class")
      edge = MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity, relation_type: "part_of")

      excess = open_transactions_at_get_lock do
        GraphDeleteService.execute_one("delete_relation", { relation_id: edge.id })
      end
      expect(excess).to eq(0)
      expect(MemoryRelation.find_by(id: edge.id)).to be_nil
    end

    it "NodeOperationsStrategy.move_to_parent takes GET_LOCK outside its transaction" do
      project = MemoryEntity.create!(name: "LockOrdMvProj", entity_type: "Project")
      node = MemoryEntity.create!(name: "LockOrdMvNode", entity_type: "Class")

      excess = open_transactions_at_get_lock do
        NodeOperationsStrategy.new.move_to_parent(node.id, project.id)
      end
      expect(excess).to eq(0)
    end

    it "ProjectIdBackfill.run takes GET_LOCK before computing" do
      excess = open_transactions_at_get_lock do
        ProjectIdBackfill.new(out: ->(_l) { }).run(dry_run: true)
      end
      expect(excess).to eq(0)
    end
  end

  describe "busy lock at the outer wrapper" do
    def hold_lock
      conn = ActiveRecord::Base.connection
      name = described_class.lock_name(conn)
      holder = stub_const("OuterLockHolder",
                          Class.new(ActiveRecord::Base) { self.abstract_class = true })
      holder.establish_connection(ActiveRecord::Base.connection_db_config)
      holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(name)}, 5)")
      yield
    ensure
      holder.connection.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})") if holder&.connection
      holder.connection_pool&.disconnect! if holder
    end

    it "GraphWriteService surfaces OperationFailed concurrency, not 'escalate'" do
      hold_lock do
        expect do
          GraphWriteService.call(operations: [
            { type: "create_entity", name: "BusyNode", entity_type: "Class" }
          ])
        end.to raise_error(McpGraphMemErrors::OperationFailed) do |error|
          expect(error.next_move).to match(/retry shortly/)
          expect(error.next_move).not_to match(/[Rr]ename|escalate/i)
        end
      end
    end

    it "GraphDeleteService.execute_one under a held lock fails atomically — edge survives" do
      from_entity = MemoryEntity.create!(name: "BusyDelFrom", entity_type: "Class")
      to_entity = MemoryEntity.create!(name: "BusyDelTo", entity_type: "Class")
      edge = MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity, relation_type: "part_of")

      hold_lock do
        expect do
          GraphDeleteService.execute_one("delete_relation", { relation_id: edge.id })
        end.to raise_error(McpGraphMemErrors::OperationFailed, /retry shortly|membership lock/i)
      end
      expect(MemoryRelation.find_by(id: edge.id)).to be_present
    end

    it "ProjectIdBackfill retries once then succeeds when the lock frees" do
      calls = 0
      allow(ProjectMembership).to receive(:with_membership_lock).and_wrap_original do |orig, **_args, &block|
        calls += 1
        raise(ProjectMembership::LockTimeout, "held") if calls == 1

        orig.call(&block)
      end
      expect { ProjectIdBackfill.new(out: ->(_l) { }).run }.not_to raise_error
      expect(calls).to eq(2)
    end
  end
end
