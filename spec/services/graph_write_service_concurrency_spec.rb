# frozen_string_literal: true

require "rails_helper"

# mcp plan PR-2 §2.7: block or queue, never crash or race.
RSpec.describe GraphWriteService, "concurrency" do
  # Real commits from two connections: no wrapping transaction, explicit cleanup.
  self.use_transactional_tests = false

  let(:name) { "SynthWidget #{SecureRandom.hex(4)}" }
  let(:create_op) { { type: "create_entity", name: name, entity_type: "Component" } }

  around do |example|
    started_at = Time.current
    example.run
  ensure
    MemoryEntity.where("name LIKE ?", "SynthWidget %").destroy_all
    AuditLog.where(created_at: started_at..).delete_all # entity writes and this cleanup are audited
    ChangeSet.where(created_at: started_at..).delete_all # each graph_write is a change set (UI-4a)
  end

  # Both writers pass the semantic check (outside the lock) before either takes the lock, so only
  # the exact check under the lock can keep the second from inserting.
  def race(&write)
    barrier = Concurrent::CyclicBarrier.new(2)
    allow_any_instance_of(VectorSearchStrategy).to receive(:search) do
      barrier.wait(5)
      []
    end
    2.times.map do
      Thread.new { ActiveRecord::Base.connection_pool.with_connection(&write) }
    end.map(&:value)
  end

  it "two concurrent batch creates of one name yield one entity and one structured duplicate" do
    results = race { GraphWriteService.new(operations: [ create_op ], logger: Logger.new(nil)).call }

    expect(MemoryEntity.where(name: name).count).to eq(1)
    expect(results.map { |result| result[:status] }).to contain_exactly("ok", "possible_duplicate")
    expect(results.find { |result| result[:status] == "possible_duplicate" }).to include(reason: "same_name")
  end

  it "does the same through the single-operation path" do
    results = race { GraphWriteService.execute_one("create_entity", create_op.except(:type), logger: Logger.new(nil)) }

    expect(MemoryEntity.where(name: name).count).to eq(1)
    expect(results.count { |result| result[:status] == "possible_duplicate" }).to eq(1)
  end

  it "turns a unique-index race inside the transaction into a possible_duplicate" do
    existing = MemoryEntity.create!(name: name, entity_type: "Component")
    allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([])
    service = GraphWriteService.new(operations: [ create_op ], logger: Logger.new(nil))
    allow(service).to receive(:exact_duplicate_response).and_return(nil) # the check "missed" the winner
    allow(MemoryEntity).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

    result = service.call

    expect(result).to include(status: "possible_duplicate", reason: "concurrent_insert")
    expect(result[:candidates].first[:entity_id]).to eq(existing.id)
  end

  it "answers retry-shortly when the write lock is busy" do
    stub_const("ProjectMembership::LOCK_TIMEOUT_SECONDS", 1)
    allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([])
    holder = ActiveRecord::Base.connection_pool.checkout
    holder.select_value("SELECT GET_LOCK(#{holder.quote(ProjectMembership.lock_name(holder))}, 0)")

    expect { GraphWriteService.new(operations: [ create_op ], logger: Logger.new(nil)).call }
      .to raise_error(McpGraphMemErrors::OperationFailed) { |error| expect(error.next_move).to include("retry shortly") }
  ensure
    holder&.select_value("SELECT RELEASE_LOCK(#{holder.quote(ProjectMembership.lock_name(holder))})")
    ActiveRecord::Base.connection_pool.checkin(holder) if holder
  end
end
