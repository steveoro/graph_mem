# frozen_string_literal: true

# Fact keyword paths (1.77.0, FactKeywords). Recompute them after entities were renamed, merged or
# their aliases changed (the facts that mention them keep the old names), or to fill them for facts
# written before 1.77.0 without waiting for the night. A fact that moves to another entity (a
# merge) is recomputed on its own.
namespace :graph_mem do
  namespace :fact_keywords do
    desc "Recompute every active fact's keyword path now (PROJECT=<name> for one project's facts)"
    task refresh: :environment do
      scope = MemoryObservation.active
      if (name = ENV["PROJECT"].to_s.strip.presence)
        project = MemoryEntity.find_by(name: name, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil)
        abort "graph_mem:fact_keywords:refresh: no Project root named #{name.inspect}" unless project

        scope = scope.where(memory_entity_id: MemoryEntity.where(project_id: project.id).select(:id))
                     .or(scope.where(memory_entity_id: project.id))
      end
      marked = scope.update_all(keywords_at: nil)
      computed = 0
      scope.keywords_pending.includes(:memory_entity).find_in_batches(batch_size: FactKeywordsJob::BATCH_SIZE) do |batch|
        computed += FactKeywords.compute!(batch)
      end
      puts "[fact_keywords] #{marked} facts marked, #{computed} computed"
    end
  end
end
