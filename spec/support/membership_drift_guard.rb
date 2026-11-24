# frozen_string_literal: true

# The membership drift guard (option 3 of the part_of membership plan): after each example it reads
# ProjectIdBackfill.drift, the one drift implementation, and fails the example when the graph it
# leaves has drifted: an entity whose project_id differs from what its part_of chain gives
# (wrong_project, stamped_without_path, path_without_stamp), one two Project roots reach, or one
# with two part_of parents. It checks the outcome, not the writer, so it catches every writer,
# direct or not (a `dependent: :destroy`, an update_all).
#
# - Scope: every example but system specs. Opt out with `membership_drift: :allowed` on an example
#   (or group) whose point is drift, with a one-line comment why; build consistent data with
#   `fs_member!` (spec/support/fact_supersede_helpers.rb) everywhere else.
# - Where it runs: a group-level `around` hook (Hook) included after rspec-rails' fixture support,
#   so it runs INSIDE the example's transactional-fixture transaction, before the rollback (it sees
#   the example's rows), and after the example's `after` hooks and mock teardown (an example's stubs
#   of the connection or the models are gone).
# - Cost: one query when the graph has no part_of edge and no project_id; the walk otherwise.
module MembershipDriftGuard
  ANY_MEMBERSHIP_SQL = "SELECT EXISTS(SELECT 1 FROM memory_relations WHERE relation_type = 'part_of') " \
                       "OR EXISTS(SELECT 1 FROM memory_entities WHERE project_id IS NOT NULL)"
  LISTED_PER_KIND = 10

  module_function

  # @raise [RSpec::Expectations::ExpectationNotMetError] when the graph has drifted
  def check!
    connection = ActiveRecord::Base.connection
    return unless connection.uncached { connection.select_value(ANY_MEMBERSHIP_SQL) }.to_i == 1

    drift = ActiveRecord::Base.uncached { ProjectIdBackfill.drift }
    raise RSpec::Expectations::ExpectationNotMetError, message(drift) if drift.any?
  end

  # @param drift [ProjectIdBackfill::Drift]
  # @return [String]
  def message(drift)
    names = MemoryEntity.where(id: drift.ids.values.flatten.uniq).pluck(:id, :name, :project_id).to_h { |id, *rest| [ id, rest ] }
    lines = drift.ids.filter_map do |kind, ids|
      next if ids.empty?

      listed = ids.first(LISTED_PER_KIND).map { |id| "##{id} '#{names.dig(id, 0)}' (project_id #{names.dig(id, 1).inspect})" }
      "  #{kind}: #{listed.join(', ')}#{' …' if ids.size > LISTED_PER_KIND}"
    end
    [ "Membership drift after this example: #{drift.summary}", *lines,
      "Build consistent data (fs_member!: a part_of edge followed by ProjectMembership.sync!), " \
      "or tag the example `membership_drift: :allowed` when drift is its point." ].join("\n")
  end

  # Included into every example group (after RSpec::Rails::FixtureSupport, whose `around` rolls
  # the fixture transaction back), so this `around` runs inside it. It records the failure on the
  # example instead of raising: an exception out of this hook would skip the fixture adapter's
  # rollback (its `after_teardown` is not in an `ensure`) and leak the rows into the next example.
  module Hook
    def self.included(group)
      group.around do |example|
        example.run
        next if example.metadata[:type] == :system || example.metadata[:membership_drift] == :allowed
        next if example.exception # already failed: its own failure says more

        begin
          MembershipDriftGuard.check!
        rescue RSpec::Expectations::ExpectationNotMetError => e
          example.example.set_exception(e)
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.include MembershipDriftGuard::Hook
end
