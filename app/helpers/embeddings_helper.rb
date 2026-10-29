# frozen_string_literal: true

module EmbeddingsHelper
  # Where a config value comes from, as a badge (the text names it; the colour only repeats it).
  SOURCE_BADGES = { "app_settings" => "ui-badge--running", "env" => "ui-badge--completed" }.freeze

  def embedding_config_source_badge(source)
    content_tag(:span, t("operator.embeddings.config.sources.#{source}"),
                class: "ui-badge #{SOURCE_BADGES[source.to_s]}".strip,
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
    content_tag(:p, class: "system-fallback", data: { testid: "embedding-fallback-#{key}" }) do
      safe_join([
        content_tag(:span, t("system.settings.embeddings.used_when_blank"), class: "system-fallback__label"),
        " ",
        content_tag(:code, fallback[:value], class: "system-fallback__value"),
        " ",
        embedding_config_source_badge(fallback[:source])
      ])
    end
  end
end
