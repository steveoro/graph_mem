# frozen_string_literal: true

module ReviewPolicies
  # Dismisses pending compaction suggestions that the dream-state producers would no longer queue
  # (1.85.0), so a backlog seeded under looser rules shrinks without a restore:
  #
  # - `entity_merge` rows compaction queued (they carry a `score`; "Import suggest merges" rows don't
  #   and are left alone): EntityMergeEvidence.qualifies? on the two live entities (boilerplate shared
  #   facts no longer count, and a pair scoring on distance alone isn't a candidate). A pair with an
  #   entity waiting for its embedding is left for a later run;
  # - `relationship_proposal`: RelationshipDiscoveryStrategy.proposal_qualifies? on the payload (the
  #   identical-content `relates_to` rule is gone; `solves` needs 3 shared terms);
  # - `orphan_parent`: none of its suggested parents passes OrphanMatchingStrategy.suggestion_qualifies?.
  #
  # A row whose entities are gone is left to the Dangling policy. No suppression: a pair whose evidence
  # grows is proposed again. Reverse: Undo the run, or Restore the row.
  #
  #   ReviewPolicies::StillQualifies.new.call # => { "acted" => 400, "skipped" => 0, ... }
  #   ReviewPolicies::StillQualifies.preview  # => { "entity_merge" => { "pending" => 234, "below_bar" => 208 }, ... }
  class StillQualifies < Base
    KINDS = %w[entity_merge relationship_proposal orphan_parent].freeze
    REASON = "below the current evidence bar"

    # What a run would dismiss, read-only and without the per-run limit (`bin/rails review:still_qualifies_report`).
    # @return [Hash{String => Hash{String => Integer}}] per kind: "pending" rows and how many are "below_bar"
    def self.preview
      policy = new
      KINDS.index_with do |kind|
        rows = MaintenanceReportRow.pending.where(kind: kind)
        { "pending" => rows.count, "below_bar" => rows.find_each.count { |row| policy.dismissible?(row) } }
      end
    end

    # @param row [MaintenanceReportRow]
    # @return [Boolean] whether a run would dismiss the row now
    def dismissible?(row) = below_bar?(row)

    private

    def verb = "dismissed"

    def candidates
      MaintenanceReportRow.pending.where(kind: KINDS).find_each.lazy
                          .select { |row| below_bar?(row) }.first(PER_RUN)
    end

    def act(row)
      return false unless %w[active ignored].include?(row.status) && below_bar?(row)

      change!(row, { status: "dismissed", dismissed_at: Time.current, resolution_reason: REASON, expires_at: nil })
    end

    # @return [Boolean] true only when the live data is there and the producer would not queue it now
    def below_bar?(row)
      payload = row.effective_payload.to_h.deep_stringify_keys
      case row.kind
      when "entity_merge" then merge_below_bar?(payload)
      when "relationship_proposal" then !RelationshipDiscoveryStrategy.proposal_qualifies?(payload)
      when "orphan_parent" then orphan_below_bar?(payload)
      else false
      end
    end

    def merge_below_bar?(payload)
      return false unless payload.key?("score")

      ids = [ payload.dig("entity_a", "entity_id"), payload.dig("entity_b", "entity_id") ].map(&:to_i)
      entities = MemoryEntity.where(id: ids).index_by(&:id)
      return false unless entities.size == 2 && entities.each_value.all?(&:embedded_at)

      !EntityMergeEvidence.qualifies?(entities[ids.first], entities[ids.last])
    end

    def orphan_below_bar?(payload)
      orphan = MemoryEntity.find_by(id: payload["entity_id"].to_i)
      return false unless orphan

      project_ids = Array(payload["suggested_parents"]).filter_map { |parent| parent["project_id"]&.to_i }
      projects = MemoryEntity.where(id: project_ids).to_a
      projects.none? { |project| OrphanMatchingStrategy.suggestion_qualifies?(orphan, project) }
    end
  end
end
