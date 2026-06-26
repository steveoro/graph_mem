# frozen_string_literal: true

# Resolves embedding service configuration: AppSettings → ENV → defaults.
class EmbeddingConfig
  DEFAULTS = {
    url: "http://localhost:11434",
    model: "nomic-embed-text",
    provider: "ollama",
    dims: 768
  }.freeze

  ALLOWED_PROVIDERS = %w[ollama openai_compatible].freeze

  ENV_KEYS = {
    url: "OLLAMA_URL",
    model: "EMBEDDING_MODEL",
    provider: "EMBEDDING_PROVIDER",
    dims: "EMBEDDING_DIMS"
  }.freeze

  APP_SETTINGS_KEYS = {
    url: :embedding_url,
    model: :embedding_model,
    provider: :embedding_provider,
    dims: :embedding_dims
  }.freeze

  class << self
    def resolved_config
      {
        url: resolve_string(:url),
        model: resolve_string(:model),
        provider: resolve_string(:provider),
        dims: resolve_dims
      }
    end

    def config_sources
      {
        url: resolve_source(:url),
        model: resolve_source(:model),
        provider: resolve_source(:provider),
        dims: resolve_dims_source
      }
    end

    # Value used when the AppSettings field is blank (ENV → default).
    def fallback_for(key)
      key = key.to_sym
      case key
      when :dims
        fallback_dims
      when :url, :model, :provider
        fallback_string(key)
      else
        raise ArgumentError, "unknown embedding config key: #{key}"
      end
    end

    def valid_provider?(value)
      value.blank? || ALLOWED_PROVIDERS.include?(value.to_s)
    end

    def validate_provider!(value)
      return if valid_provider?(value)

      raise ArgumentError, "embedding_provider must be one of: #{ALLOWED_PROVIDERS.join(', ')}"
    end

    private

    def resolve_string(key)
      app_value = AppSettings.send(APP_SETTINGS_KEYS[key])
      return app_value.to_s if app_value.present?

      env_value = ENV[ENV_KEYS[key]]
      return env_value if env_value.present?

      DEFAULTS[key].to_s
    end

    def resolve_dims
      app_dims = AppSettings.embedding_dims.to_i
      return app_dims if app_dims.positive?

      env_dims = ENV[ENV_KEYS[:dims]]
      return env_dims.to_i if env_dims.present?

      DEFAULTS[:dims]
    end

    def resolve_source(key)
      app_value = AppSettings.send(APP_SETTINGS_KEYS[key])
      return :app_settings if app_value.present?

      env_value = ENV[ENV_KEYS[key]]
      return :env if env_value.present?

      :default
    end

    def resolve_dims_source
      return :app_settings if AppSettings.embedding_dims.to_i.positive?

      env_dims = ENV[ENV_KEYS[:dims]]
      return :env if env_dims.present?

      :default
    end

    def fallback_string(key)
      env_value = ENV[ENV_KEYS[key]]
      if env_value.present?
        { value: env_value, source: :env }
      else
        { value: DEFAULTS[key].to_s, source: :default }
      end
    end

    def fallback_dims
      env_dims = ENV[ENV_KEYS[:dims]]
      if env_dims.present?
        { value: env_dims.to_i, source: :env }
      else
        { value: DEFAULTS[:dims], source: :default }
      end
    end
  end
end
