# frozen_string_literal: true

# Runtime settings persisted in the primary database (rails-settings-cached).
class AppSettings < RailsSettings::Base
  cache_prefix { "v1" }

  # Feature flags
  field :enable_dream_state_compactor, default: true, type: :boolean
  field :enable_garbage_collector, default: true, type: :boolean
  field :enable_contradiction_detection, default: true, type: :boolean
  field :enable_stale_memory_scan, default: true, type: :boolean
  field :enable_guest_access, default: true, type: :boolean

  # Database backup settings
  field :backup_folder_path, default: "db/backup", type: :string
  field :backup_keep_max, default: 10, type: :integer,
        validates: { numericality: { greater_than: 0, less_than_or_equal_to: 100 } }
  field :backup_schedule_cron, default: "N/A", type: :string, readonly: true
  field :enable_scheduled_backups, default: false, type: :boolean

  # Embedding service settings (empty / zero defers to ENV)
  field :embedding_url, default: "", type: :string
  field :embedding_model, default: "", type: :string
  field :embedding_provider, default: "", type: :string
  field :embedding_dims, default: 0, type: :integer
  field :enable_scheduled_embedding_backfill, default: false, type: :boolean
  field :embedding_backfill_schedule_cron, default: "N/A", type: :string, readonly: true

  # Summarization service settings (empty / zero defers to ENV)
  field :summary_url, default: "", type: :string
  field :summary_model, default: "", type: :string
  field :summary_provider, default: "", type: :string
  field :summary_timeout, default: 0, type: :integer
  field :summary_max_tokens, default: 0, type: :integer
  field :summary_observations_per_entity, default: 3, type: :integer
  field :enable_llm_summarization, default: false, type: :boolean

  # Import matching settings
  field :import_observation_duplicate_max_distance, default: 0.35, type: :float,
        validates: { numericality: { greater_than_or_equal_to: 0.2, less_than_or_equal_to: 0.5 } }

  # Project scan settings. project_scan_subfolders is relative to the scan root (ScanRootPolicy);
  # project_scan_roots is the pre-1.54 setting, kept one release only so Settings can show and
  # clear a leftover value (it is ignored).
  field :project_scan_subfolders, default: "Projects", type: :string
  field :project_scan_roots, default: [ Dir.pwd, Dir.home, Dir.tmpdir ].join(","), type: :string
  field :enable_project_scan_validation, default: true, type: :boolean
  field :project_scan_validation_batch_size, default: 5, type: :integer,
        validates: { numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1000 } }

  # Compaction review row retention (approved/dismissed rows are pruned after N days)
  field :compaction_review_row_retention_days, default: 30, type: :integer,
        validates: { numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 365 } }

  # Review queue limits (UI-5a). Read uncached through review_number, clamped to REVIEW_NUMBERS;
  # the Settings panel for them arrives with UI-5b.
  field :review_backlog_ceiling, default: 300, type: :integer,
        validates: { numericality: { greater_than_or_equal_to: 50, less_than_or_equal_to: 5000 } }

  # Default and accepted range of each numeric review setting.
  REVIEW_NUMBERS = {
    "review_backlog_ceiling" => [ 300, 50..5000 ]
  }.freeze

  # MCP tool invocation retention (zero disables automatic pruning)
  field :tool_invocation_retention_days, default: 90, type: :integer,
        validates: { numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 3650 } }

  def self.embedding_backfill_schedule_cron
    yaml = YAML.safe_load_file(
      Rails.root.join("config", "recurring.yml"),
      aliases: true
    )
    env_config = yaml[Rails.env] || {}
    schedules = env_config.filter_map do |_key, entry|
      entry["schedule"] if entry.is_a?(Hash) && entry["class"] == "EmbeddingScheduledBackfillJob"
    end
    schedules.presence&.join(", ") || "N/A"
  rescue StandardError => e
    Rails.logger.warn("Failed to read embedding backfill schedules from recurring.yml: #{e.message}")
    "N/A"
  end

  def self.scheduled_embedding_backfill_enabled?
    read_boolean_setting("enable_scheduled_embedding_backfill")
  end

  # The folders scans may use, as real paths (thin delegate kept for existing callers).
  #
  # @return [Array<String>]
  def self.project_scan_root_paths
    ScanRootPolicy.allowed_roots.map { |root| root[:path] }
  end

  # The subfolder filter, read straight from the table so every process (Puma, Solid Queue,
  # the stdio runner) sees a change on its next call, with no cache in between.
  #
  # @return [String] the raw comma/newline-separated value ("Projects" when unset)
  def self.project_scan_subfolders_raw
    raw = connection.select_value(
      sanitize_sql([ "SELECT value FROM #{table_name} WHERE var = ?", "project_scan_subfolders" ])
    )
    return "Projects" if raw.nil?

    YAML.safe_load(raw.to_s).to_s
  rescue StandardError
    "Projects"
  end

  # A stored pre-1.54 project_scan_roots value that is now ignored, or nil.
  #
  # @return [String, nil]
  def self.legacy_project_scan_roots
    raw = connection.select_value(
      sanitize_sql([ "SELECT value FROM #{table_name} WHERE var = ?", "project_scan_roots" ])
    )
    raw && YAML.safe_load(raw.to_s).to_s.presence
  rescue StandardError
    nil
  end

  def self.backup_schedule_cron
    yaml = YAML.safe_load_file(
      Rails.root.join("config", "recurring.yml"),
      aliases: true
    )
    env_config = yaml[Rails.env] || {}
    schedules = env_config.filter_map do |_key, entry|
      entry["schedule"] if entry.is_a?(Hash) && entry["class"] == "DatabaseBackupJob"
    end
    schedules.presence&.join(", ") || "N/A"
  rescue StandardError => e
    Rails.logger.warn("Failed to read backup schedules from recurring.yml: #{e.message}")
    "N/A"
  end

  def self.backup_config
    {
      folder_path: backup_folder_path,
      keep_max: backup_keep_max,
      schedule_cron: backup_schedule_cron,
      enabled: enable_scheduled_backups
    }
  end

  # Bypass process-local cache so Solid Queue workers see UI changes immediately.
  def self.scheduled_backups_enabled?
    read_boolean_setting("enable_scheduled_backups")
  end

  def self.dream_state_compactor_enabled?
    read_boolean_setting("enable_dream_state_compactor", default: true)
  end

  def self.garbage_collector_enabled?
    read_boolean_setting("enable_garbage_collector", default: true)
  end

  def self.contradiction_detection_enabled?
    read_boolean_setting("enable_contradiction_detection", default: true)
  end

  def self.stale_memory_scan_enabled?
    read_boolean_setting("enable_stale_memory_scan", default: true)
  end

  # Read uncached on every request, so turning it off signs guests out on their next click.
  def self.guest_access_enabled?
    read_boolean_setting("enable_guest_access", default: true)
  end

  def self.llm_summarization_enabled?
    read_boolean_setting("enable_llm_summarization", default: false)
  end

  def self.project_scan_validation_enabled?
    read_boolean_setting("enable_project_scan_validation", default: true)
  end

  def self.project_scan_validation_batch_size
    raw = connection.select_value(
      sanitize_sql([ "SELECT value FROM #{table_name} WHERE var = ?", "project_scan_validation_batch_size" ])
    )
    return 5 if raw.nil?

    YAML.safe_load(raw.to_s).to_i.clamp(0, 1000)
  rescue StandardError
    5
  end

  # Uncached read of a numeric review setting, clamped to its range (a value written outside the
  # range, e.g. from the console, can't push a limit past it).
  # @param name [String, Symbol] a key of REVIEW_NUMBERS
  # @return [Numeric]
  def self.review_number(name)
    default, range = REVIEW_NUMBERS.fetch(name.to_s)
    raw = connection.select_value(sanitize_sql([ "SELECT value FROM #{table_name} WHERE var = ?", name.to_s ]))
    value = raw.nil? ? default : YAML.safe_load(raw.to_s)
    value = default unless value.is_a?(Numeric)
    value = value.to_i if default.is_a?(Integer)
    value.clamp(range.min, range.max)
  rescue StandardError
    default
  end

  def self.read_boolean_setting(var_name, default: false)
    raw = connection.select_value(
      sanitize_sql([ "SELECT value FROM #{table_name} WHERE var = ?", var_name ])
    )
    return default if raw.nil?

    YAML.safe_load(raw.to_s) == true
  end
  private_class_method :read_boolean_setting
end
