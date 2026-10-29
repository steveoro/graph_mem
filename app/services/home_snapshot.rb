# frozen_string_literal: true

# What Home shows (UI-2b, the UI plan (docs/plans) §2.2), one section per lazy Turbo Frame
# so a slow check (the embedding service) never holds up the rest. Status only: nothing here
# changes data. Composes MaintenanceDashboardSnapshot, EmbeddingStatusSnapshot,
# AgentContextsSnapshot, ReviewDigest, OperationProgress, ChangeSet and ScanRootPolicy.status.
#
#   HomeSnapshot.section(:health)   # => [{ key: :database, status: :ok, ... }, ...]
#   HomeSnapshot.section(:digest)   # => { groups: [...], attention_count: 3, ... }
class HomeSnapshot
  SECTIONS = %i[health counts digest jobs activity clients].freeze
  DIGEST_SIZE = 5
  JOBS_SIZE = 5
  ACTIVITY_SIZE = 15

  # @param name [Symbol, String] one of SECTIONS
  # @return [Object] that section's data
  # @raise [ArgumentError] for an unknown section
  def self.section(name)
    name = name.to_sym
    raise ArgumentError, "unknown Home section: #{name.inspect}" unless SECTIONS.include?(name)

    new.public_send(name)
  end

  # @return [Array<Hash>] the health strip's pills, see HomeSnapshot::Health
  def health
    Health.new.pills
  end

  # @return [Hash] graph totals, orphans and embedding coverage
  def counts
    stats = MaintenanceDashboardSnapshot.new.graph_stats
    embeddings = EmbeddingStatusSnapshot.call
    stats[:totals].slice(:entities, :observations, :relations).merge(
      orphans: stats[:orphan_count],
      coverage_percent: embeddings[:coverage_percent],
      vector_enabled: embeddings[:vector_enabled]
    )
  end

  # @return [Hash] the top attention groups (ReviewDigest::Group) and the inbox state
  def digest
    digest = ReviewDigest.new
    last_run = MaintenanceReport.by_type("review_policy_run").recent.first
    {
      groups: digest.attention.first(DIGEST_SIZE),
      attention_count: digest.attention_count,
      below: digest.below,
      last_policy_run_at: last_run&.created_at,
      last_policy_run_resolved: policy_run_resolved(last_run)
    }
  end

  # @return [Hash] `running:` active operations, `recent:` the last finished or failed ones
  #   (OperationProgress#snapshot hashes), `compaction:` CompactionRunner.status_snapshot
  def jobs
    {
      running: OperationProgress.active.recent.limit(JOBS_SIZE).map(&:snapshot),
      recent: OperationProgress.where(status: %w[completed failed]).recent.limit(JOBS_SIZE).map(&:snapshot),
      compaction: CompactionRunner.status_snapshot
    }
  end

  # @return [Array<ChangeSet>] the latest change sets, newest first
  def activity
    ChangeSet.order(created_at: :desc, id: :desc).limit(ACTIVITY_SIZE).to_a
  end

  # @return [Hash] AgentContextsSnapshot's summary and its most recent clients
  def clients
    snapshot = AgentContextsSnapshot.call
    { summary: snapshot[:summary], clients: snapshot[:clients].first(JOBS_SIZE) }
  end

  private

  def policy_run_resolved(report)
    return 0 unless report

    Hash(report.data["policies"]).values.sum { |stats| stats.is_a?(Hash) ? stats["acted"].to_i : 0 }
  end
end
