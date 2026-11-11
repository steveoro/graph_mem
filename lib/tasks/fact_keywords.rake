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

    desc "Read-only: how many pending contradiction / \"Outdated by a fact\" rows the no_shared_subject policy would dismiss"
    task review_report: :environment do
      counts = Hash.new { |hash, kind| hash[kind] = Hash.new(0) }
      MaintenanceReportRow.pending.where(kind: ReviewPolicies::SubjectCheck::KINDS).find_each do |row|
        counts[row.kind][ReviewPolicies::SubjectCheck.status(row)] += 1
      end
      ReviewPolicies::SubjectCheck::KINDS.each do |kind|
        found = counts[kind]
        puts "[fact_keywords] #{kind}: #{found.values.sum} pending; #{found[:dismiss]} share no subject (would be dismissed), " \
             "#{found[:keep]} kept, #{found[:pending]} with a pending path (run graph_mem:fact_keywords:refresh first), " \
             "#{found[:not_applicable]} not checked (a term match, or a fact gone)"
      end
      puts "[fact_keywords] the no_shared_subject policy is #{AppSettings.review_policy_enabled?('no_shared_subject') ? 'on' : 'off'}; " \
           "fact keywords are #{AppSettings.fact_keywords_enabled? ? 'on' : 'off'}"
    end
  end
end
