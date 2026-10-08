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
  # @return [Array<Integer>] entity ids ordered by in-window observation count
  def search(window, limit: 50)
    sql, binds = window.observation_predicate
    MemoryObservation
      .active
      .where(sql, **binds)
      .group(:memory_entity_id)
      .order(Arel.sql("COUNT(*) DESC"))
      .limit(limit)
      .pluck(:memory_entity_id)
  end
end
