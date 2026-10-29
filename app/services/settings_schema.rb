# frozen_string_literal: true

# The one list of every AppSettings field the operator can change (UI-7 S2): the group it sits
# in, the page that shows the group (Settings, Backups or Access), its type and accepted range,
# its label and help (`system.settings.fields.<key>.label` / `.description`) and its validator.
# The pages render from it and their `update` saves only the posted group's keys.
#
#   group = SettingsSchema.group(:summaries)
#   group.writable_keys        # => ["enable_llm_summarization", "summary_url", ...]
#   SettingsSchema.errors(group, "summary_timeout" => "900")
#   # => { "summary_timeout" => "Timeout must be 0 (use ENV/default) or between 1 and 300 seconds." }
#
# Every AppSettings field is in exactly one group, or in LEGACY_KEYS (spec/services/settings_schema_spec.rb).
class SettingsSchema
  # @!attribute key [String] the AppSettings key
  # @!attribute type [Symbol] :boolean, :integer, :float or :string (AppSettings' own type)
  # @!attribute readonly [Boolean] shown, never written
  # @!attribute range [Range, nil] the accepted numeric range (AppSettings' `validates: numericality`)
  # @!attribute validator [Symbol, nil] a method of SettingsSchema::Validators
  # @!attribute input [Symbol, nil] :select, :textarea or :slider instead of the type's default input
  # @!attribute choices [Array<String>, nil] the options of a :select (a blank option comes first)
  # @!attribute fallback [Symbol, nil] the helper that shows the ENV value used when blank (it takes `hint`)
  # @!attribute hint [Symbol, nil] the key passed to `fallback`
  # @!attribute help [String] the i18n key of the help text
  # @!attribute partial [String, nil] a partial rendering a custom input (locals: field, value)
  Field = Data.define(:key, :type, :readonly, :range, :validator, :input, :choices, :fallback, :hint, :help, :partial) do
    # @return [String] the i18n key of the label
    def label = "system.settings.fields.#{key}.label"
  end

  # @!attribute key [Symbol] the group key (the Settings tab)
  # @!attribute page [Symbol] :settings, :backups or :access
  # @!attribute fields [Array<Field>]
  # @!attribute check [Symbol, nil] a controller method (SettingsGroupUpdate) that checks the whole
  #   group after the per-field validators, returning an alert message or nil
  # @!attribute partial [String, nil] the slim partial showing live state around the fields
  Group = Data.define(:key, :page, :fields, :check, :partial) do
    # @return [String] the i18n key of the group's title
    def title = "system.settings.groups.#{key}"

    # @return [Array<String>] the keys `update` may write
    def writable_keys = fields.reject(&:readonly).map(&:key)
  end

  # Ignored since 1.54; shown and cleared by Settings › Project scans, never written by `update`.
  LEGACY_KEYS = %w[project_scan_roots].freeze

  # The page each group is on, in tab order.
  PAGES = %i[settings backups access].freeze

  class << self
    # @param page [Symbol, nil] only the groups of this page
    # @return [Array<Group>] in tab order
    def groups(page: nil)
      page ? all.select { |group| group.page == page } : all
    end

    # @param key [String, Symbol]
    # @return [Group, nil]
    def group(key)
      all.find { |group| group.key.to_s == key.to_s }
    end

    # @param key [String]
    # @return [Field, nil]
    def field(key)
      all.each { |group| group.fields.each { |field| return field if field.key == key.to_s } }
      nil
    end

    # Checks the posted values of one group with each field's range and validator. A validator
    # may normalize its value: `posted` is updated in place (as the controller checks did).
    #
    # @param group [Group]
    # @param posted [Hash{String => String}] the posted values of this group's writable keys
    # @return [Hash{String => String}] the error message per key (empty when all are valid)
    def errors(group, posted)
      group.fields.reject(&:readonly).each_with_object({}) do |field, errors|
        if field.validator
          message, value = Validators.public_send(field.validator, posted[field.key])
          next errors[field.key] = message if message

          posted[field.key] = value if posted.key?(field.key)
        end
        range_error = out_of_range(field, posted[field.key]) if posted.key?(field.key)
        errors[field.key] = range_error if range_error
      end
    end

    # @param field [Field]
    # @param raw [String, nil] the posted value
    # @return [Boolean, Integer, Float, String] the value to store, as the old controller converted it
    def cast(field, raw)
      case field.type
      when :boolean then %w[true 1 yes on].include?(raw.to_s.downcase)
      when :integer then raw.to_i
      when :float then raw.to_f
      else field.key == "summary_model" ? raw.to_s.strip : raw.to_s
      end
    end

    private

    def out_of_range(field, raw)
      return unless field.range

      value = cast(field, raw)
      return if field.range.cover?(value)

      I18n.t("system.settings.validation.out_of_range", setting: I18n.t(field.label), min: field.range.min,
                                                        max: field.range.max, value: raw.to_s.strip)
    end

    def all
      @all ||= build.freeze
    end

    def build
      [
        define_group(:feature_flags, %w[enable_dream_state_compactor enable_garbage_collector enable_stale_memory_scan enable_contradiction_detection]),
        define_group(:embeddings, [
          define_field("embedding_url", validator: :http_url_embedding, fallback: :embedding_settings_fallback_hint, hint: :url),
          define_field("embedding_model", fallback: :embedding_settings_fallback_hint, hint: :model),
          define_field("embedding_provider", validator: :embedding_provider, input: :select, choices: EmbeddingConfig::ALLOWED_PROVIDERS,
                                      fallback: :embedding_settings_fallback_hint, hint: :provider),
          define_field("embedding_dims", validator: :embedding_dims, fallback: :embedding_settings_fallback_hint, hint: :dims),
          "enable_scheduled_embedding_backfill", "embedding_backfill_schedule_cron"
        ], partial: "system/settings/embeddings_panel"),
        define_group(:summaries, [
          "enable_llm_summarization",
          define_field("summary_url", validator: :http_url_summary, fallback: :summarization_settings_fallback_hint, hint: :url),
          define_field("summary_model", fallback: :summarization_settings_fallback_hint, hint: :model),
          define_field("summary_provider", validator: :summary_provider, input: :select, choices: SummarizationConfig::ALLOWED_PROVIDERS,
                                    fallback: :summarization_settings_fallback_hint, hint: :provider),
          define_field("summary_timeout", validator: :summary_timeout, fallback: :summarization_settings_fallback_hint, hint: :timeout),
          define_field("summary_max_tokens", validator: :summary_max_tokens, fallback: :summarization_settings_fallback_hint, hint: :max_tokens),
          define_field("summary_observations_per_entity", validator: :summary_observations_per_entity)
        ], partial: "system/settings/summaries_panel"),
        define_group(:imports, [ define_field("import_observation_duplicate_max_distance", validator: :import_distance, input: :slider) ]),
        define_group(:project_scans, [
          define_field("project_scan_subfolders", validator: :project_scan_subfolders, input: :textarea),
          "enable_project_scan_validation", "project_scan_validation_batch_size"
        ], partial: "system/settings/project_scans_panel"),
        define_group(:telemetry, %w[tool_invocation_retention_days compaction_review_row_retention_days]),
        define_group(:review_policies, review_policy_fields, check: :check_review_policies, partial: "system/settings/review_policies_panel"),
        define_group(:backups, %w[backup_folder_path backup_keep_max backup_schedule_cron enable_scheduled_backups], page: :backups),
        define_group(:access, [ "enable_guest_access", *McpAccessSettings::KEYS.map { |key| define_field(key, partial: "system/access/mcp_field") } ],
              page: :access, check: :check_mcp_access)
      ]
    end

    def review_policy_fields
      toggles = AppSettings::REVIEW_POLICY_TOGGLES.map do |policy, (key, _default)|
        define_field(key, help: "system.settings.review_policies.policies.#{policy}")
      end
      toggles + AppSettings::REVIEW_NUMBERS.keys
    end

    def define_group(key, fields, page: :settings, check: nil, partial: nil)
      Group.new(key: key, page: page, fields: fields.map { |entry| entry.is_a?(Field) ? entry : define_field(entry) }.freeze,
                check: check, partial: partial)
    end

    def define_field(key, validator: nil, input: nil, choices: nil, fallback: nil, hint: nil, help: nil, partial: nil)
      definition = AppSettings.get_field(key)
      raise ArgumentError, "unknown setting #{key}" if definition.blank?

      Field.new(key: key, type: definition[:type], readonly: definition[:readonly] == true, range: numeric_range(key),
                validator: validator, input: input, choices: choices, fallback: fallback, hint: hint,
                help: help || "system.settings.fields.#{key}.description", partial: partial)
    end

    # AppSettings' `validates: { numericality: { ... } }` as a Range (greater_than N on an integer
    # field is N + 1). rails-settings-cached registers it as a model validator on the key.
    def numeric_range(key)
      rules = AppSettings.validators_on(key.to_sym).grep(ActiveModel::Validations::NumericalityValidator).first&.options
      return unless rules

      min = rules[:greater_than_or_equal_to] || (rules[:greater_than] && rules[:greater_than] + 1)
      (min..rules[:less_than_or_equal_to])
    end
  end
end
