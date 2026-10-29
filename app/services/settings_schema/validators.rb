# frozen_string_literal: true

class SettingsSchema
  # The per-field checks that lived in Operator::SettingsController until UI-7, unchanged: same
  # messages, same accepted values. Each takes the posted value (nil when the key wasn't posted)
  # and returns `[message, value]`: message is nil when the value is accepted, and value is what
  # to store (the posted value, or its normalized form).
  module Validators
    module_function

    def embedding_provider(raw)
      [ (I18n.t("system.settings.embeddings.invalid_provider") unless EmbeddingConfig.valid_provider?(raw.to_s)), raw ]
    end

    def embedding_dims(raw)
      dims = raw.to_i
      [ (I18n.t("system.settings.embeddings.invalid_dims") if dims.positive? && (dims < 1 || dims > 4096)), raw ]
    end

    def http_url_embedding(raw)
      [ (I18n.t("system.settings.embeddings.invalid_url") unless blank_or_http_url?(raw)), raw ]
    end

    def summary_provider(raw)
      [ (I18n.t("system.settings.summaries.invalid_provider") unless SummarizationConfig.valid_provider?(raw.to_s)), raw ]
    end

    def summary_timeout(raw)
      timeout = raw.to_i
      [ (I18n.t("system.settings.summaries.invalid_timeout") if timeout.positive? && (timeout < 1 || timeout > 300)), raw ]
    end

    def summary_max_tokens(raw)
      max_tokens = raw.to_i
      [ (I18n.t("system.settings.summaries.invalid_max_tokens") if max_tokens.positive? && (max_tokens < 16 || max_tokens > 4096)), raw ]
    end

    def summary_observations_per_entity(raw)
      per_entity = raw.to_s
      invalid = per_entity.present? && (per_entity.to_i.negative? || per_entity.to_i > 100)
      [ (I18n.t("system.settings.summaries.invalid_observations_per_entity") if invalid), raw ]
    end

    def http_url_summary(raw)
      [ (I18n.t("system.settings.summaries.invalid_url") unless blank_or_http_url?(raw)), raw ]
    end

    def import_distance(raw)
      [ (I18n.t("system.settings.imports.invalid_observation_duplicate_max_distance") unless raw.to_f.between?(0.2, 0.5)), raw ]
    end

    # Validates the subfolder filter entry by entry (PR-0 §0.2) and stores the entries relative to
    # the scan root. A blank filter is allowed (the whole home, minus the denylist); a folder that
    # doesn't exist yet is saved and shown as missing.
    def project_scan_subfolders(raw)
      return [ nil, raw ] if raw.nil?

      roots = ScanRootPolicy.hard_roots.filter_map { |root| root[:path] unless root[:error] }
      entries = ScanRootPolicy::Subfolders.parse(raw, hard_roots: roots)
      errors = entries.select { |entry| entry[:error] }.map { |entry| "#{entry[:input]} #{entry[:error]}" }
      return [ I18n.t("system.settings.project_scans.invalid_subfolders", errors: errors.join("; ")), raw ] if errors.any?

      [ nil, ScanRootPolicy::Subfolders.join(entries.map { |entry| entry[:path] }) ]
    end

    def blank_or_http_url?(raw)
      url = raw.to_s.strip
      return true if url.blank?

      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end
  end
end
