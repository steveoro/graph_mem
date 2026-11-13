# frozen_string_literal: true

# What "Run all scheduled jobs now" runs (1.81.0): every entry of this environment's section of
# config/recurring.yml, each once (two entries with the same class or command count as one), in
# ORDER: a backup first, then the jobs that delete or merge, then the ones that read what those
# changed. An entry missing from ORDER runs after the listed ones, so a job added to the schedule
# later is never skipped (spec/services/scheduled_run_spec.rb flags it, to place it in ORDER).
# ScheduledRunJob runs the steps. ScheduledRunCatchUpJob (1.86.0), which starts the run, is in the
# schedule but is never a step (EXCLUDED).
#
#   ScheduledRun.steps.map(&:entry) # => ["DatabaseBackupJob", "GarbageCollectionJob", …]
#   ScheduledRun.steps.first.label  # => "Database backup"
module ScheduledRun
  SCHEDULE_PATH = Rails.root.join("config/recurring.yml").freeze

  ORDER = %w[
    DatabaseBackupJob GarbageCollectionJob DreamStateCompactionJob EmbeddingScheduledBackfillJob FactKeywordsJob
    StaleMemoryScanJob ReviewPolicyJob MaintenanceReportRowCleanupJob ChangeSetPruneJob ExportJob.cleanup_old_exports
  ].freeze

  # Each job's own on/off setting (an AppSettings predicate): a step whose setting is off is skipped.
  SETTINGS = {
    "DatabaseBackupJob" => :scheduled_backups_enabled?,
    "GarbageCollectionJob" => :garbage_collector_enabled?,
    "DreamStateCompactionJob" => :dream_state_compactor_enabled?,
    "EmbeddingScheduledBackfillJob" => :scheduled_embedding_backfill_enabled?,
    "FactKeywordsJob" => :fact_keywords_enabled?,
    "StaleMemoryScanJob" => :stale_memory_scan_enabled?
  }.freeze

  # Jobs that stop between batches when a stop is requested (CooperativeStop); their progress lives
  # in the database, so running them again continues the work.
  STOPPABLE = %w[EmbeddingScheduledBackfillJob FactKeywordsJob].freeze

  # Schedule entries that are not steps of the run: the catch-up job starts the run, so it can't be one.
  EXCLUDED = %w[ScheduledRunCatchUpJob].freeze

  COMPACTION = "DreamStateCompactionJob"
  CLASS_NAME = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
  COMMAND = /\A(?<receiver>[A-Z]\w*(?:::[A-Z]\w*)*)\.(?<method>[a-z_]\w*[!?]?)\z/

  # Arguments a step's job is performed with.
  ARGS = { "ReviewPolicyJob" => { trigger: "scheduled_run" } }.freeze

  # One job of the run. `entry` is the job class name, or the command (a Ruby expression from
  # config/recurring.yml); `schedule` its schedule there.
  Step = Data.define(:entry, :schedule) do
    # @return [String] "Database backup" for DatabaseBackupJob; a command as written
    def label
      command? ? entry : entry.delete_suffix("Job").underscore.humanize
    end

    # @return [Boolean] false when the job's own setting (SETTINGS) is off
    def enabled?
      setting = SETTINGS[entry]
      setting.nil? || AppSettings.public_send(setting)
    end

    def compaction? = entry == COMPACTION

    def stoppable? = STOPPABLE.include?(entry)

    def command? = !entry.match?(CLASS_NAME)

    # Performs the job inline, or calls the command's class method. A command is never evaluated:
    # only the `Class.method` form (ExportJob.cleanup_old_exports) runs.
    #
    # @raise [ArgumentError] for a command of another form
    def run!
      return entry.constantize.perform_now(**ARGS.fetch(entry, {})) unless command?

      match = entry.match(COMMAND)
      raise ArgumentError, "#{entry}: not a Class.method command" unless match

      match[:receiver].constantize.public_send(match[:method])
    end
  end

  module_function

  # @param env [String] the recurring.yml section
  # @param path [Pathname] the schedule file (specs pass a synthetic one)
  # @return [Array<Step>] in ORDER, then the unlisted entries in file order
  def steps(env: Rails.env, path: SCHEDULE_PATH)
    section = YAML.safe_load(path.read, aliases: true)&.fetch(env.to_s, nil) || {}
    steps = section.values.filter_map do |config|
      entry = config["class"] || config["command"]
      Step.new(entry: entry, schedule: config["schedule"]) if entry && EXCLUDED.exclude?(entry)
    end
    steps = steps.uniq(&:entry)
    steps.sort_by.with_index { |step, index| [ ORDER.index(step.entry) || ORDER.size, index ] }
  end
end
