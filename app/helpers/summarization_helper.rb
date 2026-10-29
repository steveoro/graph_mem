# frozen_string_literal: true

module SummarizationHelper
  def summarization_settings_fallback_hint(key)
    fallback = SummarizationConfig.fallback_for(key)
    content_tag(:p, class: "system-fallback", data: { testid: "summary-fallback-#{key}" }) do
      safe_join([
        content_tag(:span, t("system.settings.summaries.used_when_blank"), class: "system-fallback__label"),
        " ",
        content_tag(:code, fallback[:value], class: "system-fallback__value"),
        " ",
        embedding_config_source_badge(fallback[:source])
      ])
    end
  end
end
