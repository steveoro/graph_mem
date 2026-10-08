# frozen_string_literal: true

# Deterministic temporal search channel for hybrid recall.
#
# Ranks entities by how many active observations fall inside the requested
# TemporalWindow — the observation-level predicate (occurred window for dated
# facts, retention time for undated ones) lives in TemporalWindow so the SQL and
# Ruby-side checks cannot drift apart.
class TemporalSearchStrategy
  # @param window [TemporalWindow]
  # @param limit [Integer]
  # @param entity_ids [Array<Integer>, nil] optional scope — when given the SQL
  #   only counts observations of these entities (scope applied inside the query,
  #   not after the global top-N)
  # @return [Array<Integer>] entity ids ordered by in-window observation count
  def search(window, limit: 50, entity_ids: nil)
    sql, binds = window.observation_predicate
    scope = MemoryObservation.active.where(sql, **binds)
    scope = scope.where(memory_entity_id: entity_ids) if entity_ids.present?

    scope
      .group(:memory_entity_id)
      .order(Arel.sql("COUNT(*) DESC, memory_entity_id ASC"))
      .limit(limit)
      .pluck(:memory_entity_id)
  end
end
