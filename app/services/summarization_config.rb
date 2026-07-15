# frozen_string_literal: true

# Resolves summarization service configuration: AppSettings → ENV → defaults.
class SummarizationConfig
  DEFAULTS = {
    url: "http://localhost:11434",
    model: "qwen3:8b",
    provider: "ollama",
    timeout: 30,
    max_tokens: 256
  }.freeze

  ALLOWED_PROVIDERS = %w[ollama openai_compatible].freeze

  ENV_KEYS = {
    url: "SUMMARY_URL",
    model: "SUMMARY_MODEL",
    provider: "SUMMARY_PROVIDER",
    timeout: "SUMMARY_TIMEOUT",
    max_tokens: "SUMMARY_MAX_TOKENS"
  }.freeze

  APP_SETTINGS_KEYS = {
    url: :summary_url,
    model: :summary_model,
    provider: :summary_provider,
    timeout: :summary_timeout,
    max_tokens: :summary_max_tokens
  }.freeze

  class << self
    def resolved_config
      {
        url: resolve_string(:url),
        model: resolve_string(:model),
        provider: resolve_string(:provider),
        timeout: resolve_integer(:timeout),
        max_tokens: resolve_integer(:max_tokens),
        llm_enabled: AppSettings.llm_summarization_enabled?
      }
    end

    def config_sources
      {
        url: resolve_source(:url),
        model: resolve_source(:model),
        provider: resolve_source(:provider),
        timeout: resolve_integer_source(:timeout),
        max_tokens: resolve_integer_source(:max_tokens),
        llm_enabled: :app_settings
      }
    end

    def fallback_for(key)
      key = key.to_sym
      case key
      when :timeout, :max_tokens
        fallback_integer(key)
      when :url, :model, :provider
        fallback_string(key)
      else
        raise ArgumentError, "unknown summarization config key: #{key}"
      end
    end

    def valid_provider?(value)
      value.blank? || ALLOWED_PROVIDERS.include?(value.to_s)
    end

    def validate_provider!(value)
      return if valid_provider?(value)

      raise ArgumentError, "summary_provider must be one of: #{ALLOWED_PROVIDERS.join(', ')}"
    end

    def llm_usable?
      config = resolved_config
      config[:llm_enabled] &&
        config[:url].present? &&
        config[:model].present? &&
        valid_provider?(config[:provider])
    end

    private

    def resolve_string(key)
      app_value = normalize_string(AppSettings.send(APP_SETTINGS_KEYS[key]), key)
      return app_value if app_value.present?

      env_value = normalize_string(env_string(key), key)
      return env_value if env_value.present?

      DEFAULTS[key].to_s
    end

    def resolve_integer(key)
      app_value = AppSettings.send(APP_SETTINGS_KEYS[key]).to_i
      return app_value if app_value.positive?

      env_value = ENV[ENV_KEYS[key]]
      return env_value.to_i if env_value.present? && env_value.to_i.positive?

      DEFAULTS[key]
    end

    def resolve_source(key)
      app_value = normalize_string(AppSettings.send(APP_SETTINGS_KEYS[key]), key)
      return :app_settings if app_value.present?

      env_value = normalize_string(env_string(key), key)
      return :env if env_value.present?

      :default
    end

    def resolve_integer_source(key)
      app_value = AppSettings.send(APP_SETTINGS_KEYS[key]).to_i
      return :app_settings if app_value.positive?

      env_value = ENV[ENV_KEYS[key]]
      return :env if env_value.present? && env_value.to_i.positive?

      :default
    end

    def env_string(key)
      case key
      when :url
        ENV[ENV_KEYS[:url]].presence || ENV["OLLAMA_URL"].presence
      else
        ENV[ENV_KEYS[key]].presence
      end
    end

    def fallback_string(key)
      env_value = normalize_string(env_string(key), key)
      if env_value.present?
        { value: env_value, source: :env }
      else
        { value: DEFAULTS[key].to_s, source: :default }
      end
    end

    def normalize_string(value, key)
      str = value.to_s
      return str.strip if key == :model

      str
    end

    def fallback_integer(key)
      env_value = ENV[ENV_KEYS[key]]
      if env_value.present? && env_value.to_i.positive?
        { value: env_value.to_i, source: :env }
      else
        { value: DEFAULTS[key], source: :default }
      end
    end
  end
end
