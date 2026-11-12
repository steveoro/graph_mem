# frozen_string_literal: true

# Fact keyword paths (1.77.0, FactKeywords). Recompute them after entities were renamed, merged or
# their aliases changed (the facts that mention them keep the old names), or to fill them for facts
# written before 1.77.0 without waiting for the night. A fact that moves to another entity (a
# merge) is recomputed on its own.
namespace :graph_mem do
  namespace :fact_keywords do
    desc "Recompute every active fact's keyword path now (PROJECT=<name> for one project's facts)"
    task refresh: :environment do
      scope = begin
        FactKeywords.active_facts(project: ENV["PROJECT"])
      rescue ArgumentError => e
        abort "graph_mem:fact_keywords:refresh: #{e.message}"
      end
      marked = scope.update_all(keywords_at: nil)
      computed = 0
      scope.keywords_pending.includes(:memory_entity).find_in_batches(batch_size: FactKeywordsJob::BATCH_SIZE) do |batch|
        computed += FactKeywords.compute!(batch)
      end
      puts "[fact_keywords] #{marked} facts marked, #{computed} computed"
    end

    desc "Recompute the LLM words of every active fact now (PROJECT=<name> for one project's facts; needs the summary LLM)"
    task llm_refresh: :environment do
      scope = begin
        FactKeywords.active_facts(project: ENV["PROJECT"])
      rescue ArgumentError => e
        abort "graph_mem:fact_keywords:llm_refresh: #{e.message}"
      end
      marked = scope.update_all(llm_keywords_at: nil)
      computed = 0
      scope.where.not(keywords_at: nil).llm_words_pending.includes(:memory_entity)
           .find_in_batches(batch_size: FactKeywords::LlmWords::BATCH_SIZE) { |batch| computed += FactKeywords::LlmWords.compute!(batch) }
      puts "[fact_keywords] #{marked} facts marked, #{computed} computed"
    end

    desc "Read-only: active facts' LLM words, pending, with words and without (PROJECT=<name> for one project)"
    task llm_report: :environment do
      scope = begin
        FactKeywords.active_facts(project: ENV["PROJECT"])
      rescue ArgumentError => e
        abort "graph_mem:fact_keywords:llm_report: #{e.message}"
      end
      pending = scope.llm_words_pending.count
      done = scope.where.not(llm_keywords_at: nil)
      without = done.where("JSON_LENGTH(memory_observations.llm_keywords) = 0").count
      puts "[fact_keywords] LLM words: #{pending} pending, #{done.count - without} with words, #{without} without " \
           "(the setting is #{AppSettings.llm_keywords_enabled? ? 'on' : 'off'})"
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
