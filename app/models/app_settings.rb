# frozen_string_literal: true

# Runtime settings persisted in the primary database (rails-settings-cached).
class AppSettings < RailsSettings::Base
  cache_prefix { "v1" }

  # Feature flags
  field :enable_dream_state_compactor, default: true, type: :boolean
  field :enable_garbage_collector, default: true, type: :boolean

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

  def self.read_boolean_setting(var_name, default: false)
    raw = connection.select_value(
      sanitize_sql([ "SELECT value FROM #{table_name} WHERE var = ?", var_name ])
    )
    return default if raw.nil?

    YAML.safe_load(raw.to_s) == true
  end
  private_class_method :read_boolean_setting
end
