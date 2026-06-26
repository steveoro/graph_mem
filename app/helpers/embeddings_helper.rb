# frozen_string_literal: true

module EmbeddingsHelper
  def embedding_config_source_badge(source)
    content_tag(:span, t("operator.embeddings.config.sources.#{source}"),
                class: "embeddings-source-badge embeddings-source-badge--#{source}",
                data: { testid: "embedding-source-#{source}" })
  end

  def embedding_config_row(label, value, source)
    safe_join([
      content_tag(:dt, label),
      content_tag(:dd) do
        safe_join([ value, " ", embedding_config_source_badge(source) ])
      end
    ])
  end

  def embedding_settings_fallback_hint(key)
    fallback = EmbeddingConfig.fallback_for(key)
    content_tag(:p, class: "dashboard-settings-field__fallback", data: { testid: "embedding-fallback-#{key}" }) do
      safe_join([
        content_tag(:span, t("operator.settings.embeddings.used_when_blank"), class: "dashboard-settings-field__fallback-label"),
        " ",
        content_tag(:code, fallback[:value], class: "dashboard-settings-field__fallback-value"),
        " ",
        embedding_config_source_badge(fallback[:source])
      ])
    end
  end
end
