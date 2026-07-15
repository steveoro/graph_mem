# frozen_string_literal: true

module SummarizationHelper
  def summarization_settings_fallback_hint(key)
    fallback = SummarizationConfig.fallback_for(key)
    content_tag(:p, class: "dashboard-settings-field__fallback", data: { testid: "summary-fallback-#{key}" }) do
      safe_join([
        content_tag(:span, t("operator.settings.summaries.used_when_blank"), class: "dashboard-settings-field__fallback-label"),
        " ",
        content_tag(:code, fallback[:value], class: "dashboard-settings-field__fallback-value"),
        " ",
        embedding_config_source_badge(fallback[:source])
      ])
    end
  end
end
