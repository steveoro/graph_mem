# frozen_string_literal: true

module Operator
  class SettingsController < BaseController
    before_action :load_backup_files, only: :index

    def index
      AppSettings.clear_cache
      @settings_by_group = group_settings_by_category
      @active_tab = params[:tab].presence || "feature_flags"
    end

    def bulk_update
      settings = params[:settings] || {}
      results = { success: [], failed: [] }

      if params[:tab] == "embeddings"
        validation_error = validate_embeddings_settings(settings)
        if validation_error
          flash[:alert] = validation_error
          redirect_to operator_settings_path(tab: params[:tab])
          return
        end
      end

      if params[:tab] == "summaries"
        validation_error = validate_summaries_settings(settings)
        if validation_error
          flash[:alert] = validation_error
          redirect_to operator_settings_path(tab: params[:tab])
          return
        end
      end

      settings.each do |key, value|
        next unless AppSettings.defined_fields.map(&:key).include?(key)

        field = AppSettings.get_field(key)
        next if field[:readonly] || field["readonly"]

        field_type = field[:type] || field["type"]
        converted_value = convert_value(value, field_type, key: key)
        AppSettings.send("#{key}=", converted_value)
        results[:success] << { key: key, value: AppSettings.send(key) }
      rescue StandardError => e
        results[:failed] << { key: key, error: e.message }
      end

      if results[:failed].empty?
        flash[:notice] = t("operator.settings.bulk_update.success", count: results[:success].count)
        EmbeddingService.reset_instance! if params[:tab] == "embeddings"
        SummaryGenerationClient.reset_instance! if params[:tab] == "summaries"
      else
        flash[:alert] = t("operator.settings.bulk_update.partial",
                          success: results[:success].count,
                          failed: results[:failed].count)
      end

      redirect_to operator_settings_path(tab: params[:tab])
    end

    def run_backup
      BackupFileService.new.run_backup!
      flash[:notice] = t("operator.settings.backup.run_success")
    rescue StandardError => e
      flash[:alert] = t("operator.settings.backup.run_failed", error: e.message)
    ensure
      redirect_to operator_settings_path(tab: "database_backup")
    end

    def restore_backup
      BackupFileService.new.restore!(params[:filename])
      flash[:notice] = t("operator.settings.backup.restore_success", filename: params[:filename])
    rescue StandardError => e
      flash[:alert] = t("operator.settings.backup.restore_failed", error: e.message)
    ensure
      redirect_to operator_settings_path(tab: "database_backup")
    end

    def destroy_backup
      BackupFileService.new.delete!(params[:filename])
      flash[:notice] = t("operator.settings.backup.delete_success", filename: params[:filename])
    rescue StandardError => e
      flash[:alert] = t("operator.settings.backup.delete_failed", error: e.message)
    ensure
      redirect_to operator_settings_path(tab: "database_backup")
    end

    private

    def load_backup_files
      @backup_files = BackupFileService.new.list
    end

    def group_settings_by_category
      {
        feature_flags: {
          title: t("operator.settings.groups.feature_flags"),
          settings: %w[enable_dream_state_compactor enable_garbage_collector]
        },
        database_backup: {
          title: t("operator.settings.groups.database_backup"),
          settings: %w[backup_folder_path backup_keep_max backup_schedule_cron enable_scheduled_backups]
        },
        embeddings: {
          title: t("operator.settings.groups.embeddings"),
          settings: %w[
            embedding_url embedding_model embedding_provider embedding_dims
            enable_scheduled_embedding_backfill embedding_backfill_schedule_cron
          ]
        },
        summaries: {
          title: t("operator.settings.groups.summaries"),
          settings: %w[
            enable_llm_summarization summary_url summary_model summary_provider
            summary_timeout summary_max_tokens
          ]
        }
      }
    end

    def validate_embeddings_settings(settings)
      provider = settings["embedding_provider"].to_s
      unless EmbeddingConfig.valid_provider?(provider)
        return t("operator.settings.embeddings.invalid_provider")
      end

      dims = settings["embedding_dims"].to_i
      if dims.positive? && (dims < 1 || dims > 4096)
        return t("operator.settings.embeddings.invalid_dims")
      end

      url = settings["embedding_url"].to_s.strip
      if url.present? && !valid_embedding_url?(url)
        return t("operator.settings.embeddings.invalid_url")
      end

      nil
    end

    def validate_summaries_settings(settings)
      provider = settings["summary_provider"].to_s
      unless SummarizationConfig.valid_provider?(provider)
        return t("operator.settings.summaries.invalid_provider")
      end

      timeout = settings["summary_timeout"].to_i
      if timeout.positive? && (timeout < 1 || timeout > 300)
        return t("operator.settings.summaries.invalid_timeout")
      end

      max_tokens = settings["summary_max_tokens"].to_i
      if max_tokens.positive? && (max_tokens < 16 || max_tokens > 4096)
        return t("operator.settings.summaries.invalid_max_tokens")
      end

      url = settings["summary_url"].to_s.strip
      if url.present? && !valid_embedding_url?(url)
        return t("operator.settings.summaries.invalid_url")
      end

      nil
    end

    def valid_embedding_url?(url)
      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end

    def convert_value(value, type, key: nil)
      case type
      when :boolean
        return false if value.nil? || value == "" || value == "0" || value.to_s.downcase == "false"

        %w[true 1 yes on].include?(value.to_s.downcase)
      when :integer
        value.to_i
      else
        str = value.to_s
        str = str.strip if key == "summary_model"
        str
      end
    end
  end
end
