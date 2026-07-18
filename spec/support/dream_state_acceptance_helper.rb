# frozen_string_literal: true

# Deterministic graph fixture and metrics for dream-state acceptance benchmarks.
module DreamStateAcceptanceHelper
  GraphSnapshot = Struct.new(
    :entity_count,
    :observation_count,
    :relation_count,
    :dream_state_orphan_count,
    :gc_orphan_count,
    :duplicate_observation_groups,
    keyword_init: true
  )

  AcceptanceGraph = Struct.new(
    :bench_project,
    :bench_project2,
    :auto_orphan,
    :review_orphan,
    :filler_orphans,
    :linked_child,
    :merge_source_auto,
    :merge_target_auto,
    :merge_source_review,
    :merge_target_review,
    :control_task,
    :unrelated_control,
    :discovery_issue,
    :discovery_solution,
    :retrieval_queries,
    keyword_init: true
  )

  module_function

  def build_acceptance_graph!
    bench_project = MemoryEntity.create!(name: "BenchProject", entity_type: "Project")
    bench_project2 = MemoryEntity.create!(name: "BenchProject2", entity_type: "Project")

    auto_orphan = MemoryEntity.create!(name: "BenchProject_autotask", entity_type: "Task")
    review_orphan = MemoryEntity.create!(name: "AmbiguousOrphan_Bench", entity_type: "Task")
    filler_orphans = 6.times.map do |i|
      MemoryEntity.create!(name: "FillerOrphan#{i + 1}", entity_type: "Task")
    end
    unrelated_control = MemoryEntity.create!(name: "UnrelatedControlTask", entity_type: "Task")

    linked_child = MemoryEntity.create!(name: "BenchProject_linked_child", entity_type: "Task")
    link_child!(linked_child, bench_project)
    3.times { MemoryObservation.create!(memory_entity: linked_child, content: "bench duplicate note") }
    MemoryObservation.create!(memory_entity: linked_child, content: "unique linked note")

    merge_source_auto = MemoryEntity.create!(name: "BenchProject_merge_auto_source", entity_type: "Task")
    merge_target_auto = MemoryEntity.create!(name: "BenchProject_merge_auto_target", entity_type: "Task")
    link_child!(merge_source_auto, bench_project)
    link_child!(merge_target_auto, bench_project)
    MemoryObservation.create!(memory_entity: merge_source_auto, content: "auto merge provenance")
    assign_test_embedding!(merge_source_auto, 1.0, 0.0, 0.0)
    assign_test_embedding!(merge_target_auto, 1.0, 0.0, 0.0)

    merge_source_review = MemoryEntity.create!(name: "BenchProject_merge_review_source", entity_type: "Task")
    merge_target_review = MemoryEntity.create!(name: "BenchProject_merge_review_target", entity_type: "Task")
    link_child!(merge_source_review, bench_project)
    link_child!(merge_target_review, bench_project)
    assign_test_embedding!(merge_source_review, 0.0, 1.0, 0.0)
    assign_test_embedding!(merge_target_review, 0.0, 0.8, 0.6)

    control_task = MemoryEntity.create!(name: "BenchProject2_control_task", entity_type: "Task")
    link_child!(control_task, bench_project2)
    MemoryObservation.create!(memory_entity: control_task, content: "control observation")
    assign_test_embedding!(control_task, 0.0, 0.0, 1.0)

    shared_discovery_phrase = "Shared dependency on BenchProject auth module"
    MemoryObservation.create!(memory_entity: linked_child, content: shared_discovery_phrase)
    MemoryObservation.create!(memory_entity: control_task, content: shared_discovery_phrase)

    discovery_issue = MemoryEntity.create!(name: "Login_auth_issue", entity_type: "Issue")
    discovery_solution = MemoryEntity.create!(name: "Login_auth_fix", entity_type: "PossibleSolution")
    MemoryObservation.create!(memory_entity: discovery_issue, content: "Blocks BenchProject login flow")
    MemoryObservation.create!(memory_entity: discovery_solution, content: "Fixes BenchProject login flow")

    AcceptanceGraph.new(
      bench_project: bench_project,
      bench_project2: bench_project2,
      auto_orphan: auto_orphan,
      review_orphan: review_orphan,
      filler_orphans: filler_orphans,
      linked_child: linked_child,
      merge_source_auto: merge_source_auto,
      merge_target_auto: merge_target_auto,
      merge_source_review: merge_source_review,
      merge_target_review: merge_target_review,
      control_task: control_task,
      unrelated_control: unrelated_control,
      discovery_issue: discovery_issue,
      discovery_solution: discovery_solution,
      retrieval_queries: {
        bench_project: "BenchProject",
        auto_merge: "merge_auto_source",
        control_task: "BenchProject2_control"
      }
    )
  end

  def link_child!(child, parent)
    MemoryRelation.create!(
      from_entity: child,
      to_entity: parent,
      relation_type: "part_of"
    )
  end

  def assign_test_embedding!(entity, *leading_values)
    vector = Array.new(768, 0.0)
    leading_values.each_with_index { |value, index| vector[index] = value.to_f }

    literal = "[#{vector.join(',')}]"
    quoted = ActiveRecord::Base.connection.quote(literal)
    ActiveRecord::Base.connection.execute(
      "UPDATE memory_entities SET embedding = VEC_FromText(#{quoted}) WHERE id = #{entity.id}"
    )
    entity.reload
  end

  def graph_health_snapshot
    GraphSnapshot.new(
      entity_count: MemoryEntity.count,
      observation_count: MemoryObservation.count,
      relation_count: MemoryRelation.count,
      dream_state_orphan_count: OrphanMatchingStrategy.new.orphan_nodes.count,
      gc_orphan_count: gc_orphan_count,
      duplicate_observation_groups: duplicate_observation_groups_count
    )
  end

  def gc_orphan_count
    MemoryEntity
      .left_joins(:memory_observations)
      .where(memory_observations: { id: nil })
      .where.not(id: MemoryRelation.select(:from_entity_id))
      .where.not(id: MemoryRelation.select(:to_entity_id))
      .count
  end

  def duplicate_observation_groups_count
    MemoryObservation
      .group(:memory_entity_id, :content)
      .having("COUNT(*) > 1")
      .count
      .size
  end

  def retrieval_entity_ids(query, limit: 10)
    EntitySearchStrategy.new.search(query, limit: limit).map { |result| result.entity.id }
  end

  def drain_compaction_jobs!(max_iterations: 100)
    max_iterations.times do
      job = enqueued_jobs.find { |entry| entry[:job] == DreamStateCompactionJob }
      break unless job

      perform_enqueued_jobs(only: DreamStateCompactionJob)

      run = CompactionRun.order(:id).last
      break if run&.status.in?(%w[completed paused failed])
    end
  end

  def run_compaction_via_jobs!
    run = CompactionRunner.start_or_resume!
    drain_compaction_jobs!
    run.reload
  end

  def compaction_review_items
    MaintenanceReportRow
      .by_report_type("compaction_review")
      .order(created_at: :desc)
      .map(&:payload)
  end

  def cosine_distance_between(entity_a, entity_b)
    row = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
      SELECT VEC_DISTANCE_COSINE(
        (SELECT embedding FROM memory_entities WHERE id = #{entity_a.id}),
        (SELECT embedding FROM memory_entities WHERE id = #{entity_b.id})
      ) AS distance
    SQL
    row["distance"].to_f
  end
end

RSpec.configure do |config|
  config.include DreamStateAcceptanceHelper
  config.include ActiveJob::TestHelper
end
