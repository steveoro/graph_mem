# frozen_string_literal: true

module Operator
  class SettingsController < BaseController
    include ReviewPolicySettings
    include McpAccessSettings

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

      if params[:tab] == "imports"
        validation_error = validate_import_settings(settings)
        if validation_error
          flash[:alert] = validation_error
          redirect_to operator_settings_path(tab: params[:tab])
          return
        end
      end

      if params[:tab] == "project_scans"
        validation_error = validate_project_scans_settings(settings)
        if validation_error
          flash[:alert] = validation_error
          redirect_to operator_settings_path(tab: params[:tab])
          return
        end
      end

      # Review policy settings are validated wherever they come from; out of range → 422, nothing saved.
      review_error = review_policy_settings_error(settings)
      return render_review_policy_error(review_error) if review_error

      # MCP allowlists likewise: any refused entry → 422, nothing saved.
      mcp_errors = mcp_access_settings_errors(settings)
      return render_mcp_access_error(mcp_errors) if mcp_errors

      review_before = review_policy_values
      mcp_before = mcp_access_values
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

      audit_review_policy_changes(review_before)
      apply_mcp_access_changes(mcp_before)
      if results[:failed].empty?
        flash[:notice] = [ t("operator.settings.bulk_update.success", count: results[:success].count), mcp_access_warnings_notice ].compact.join(" ")
        EmbeddingService.reset_instance! if params[:tab] == "embeddings"
        SummaryGenerationClient.reset_instance! if params[:tab] == "summaries"
      else
        flash[:alert] = t("operator.settings.bulk_update.partial",
                          success: results[:success].count,
                          failed: results[:failed].count)
      end

      redirect_to operator_settings_path(tab: params[:tab])
    end

    # GET /operator/settings/project_scans/check_path?path= (Turbo Frame): what ScanRootPolicy
    # would do with a path, without queueing anything.
    def check_scan_path
      @scan_path_result = params[:path].present? ? ScanRootPolicy.resolve(params[:path]) : nil
      render partial: "operator/settings/scan_path_check", locals: { result: @scan_path_result, path: params[:path] }
    end

    # DELETE /operator/settings/project_scans/legacy_roots: drop the ignored pre-1.54 value.
    def clear_legacy_scan_roots
      AppSettings.where(var: "project_scan_roots").delete_all
      AppSettings.clear_cache
      flash[:notice] = t("operator.settings.project_scans.legacy_cleared")
      redirect_to operator_settings_path(tab: "project_scans")
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
      # The restored settings may carry other MCP allowlists: apply them now, not at the next restart.
      GraphMem::OfficialMcp.refresh_access!(transports: true)
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
          settings: %w[enable_dream_state_compactor enable_garbage_collector enable_stale_memory_scan enable_guest_access]
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
            summary_timeout summary_max_tokens summary_observations_per_entity
          ]
        },
        imports: {
          title: t("operator.settings.groups.imports"),
          settings: %w[import_observation_duplicate_max_distance]
        },
        project_scans: {
          title: t("operator.settings.groups.project_scans"),
          settings: %w[project_scan_subfolders enable_project_scan_validation]
        },
        telemetry: {
          title: t("operator.settings.groups.telemetry"),
          settings: %w[tool_invocation_retention_days compaction_review_row_retention_days]
        },
        review_policies: {
          title: t("operator.settings.groups.review_policies"),
          settings: ReviewPolicySettings::KEYS
        },
        mcp_access: {
          title: t("operator.settings.groups.mcp_access"),
          settings: McpAccessSettings::KEYS
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

      per_entity = settings["summary_observations_per_entity"].to_s
      if per_entity.present? && (per_entity.to_i.negative? || per_entity.to_i > 100)
        return t("operator.settings.summaries.invalid_observations_per_entity")
      end

      url = settings["summary_url"].to_s.strip
      if url.present? && !valid_embedding_url?(url)
        return t("operator.settings.summaries.invalid_url")
      end

      nil
    end

    def validate_import_settings(settings)
      distance = settings["import_observation_duplicate_max_distance"].to_f
      return if distance.between?(0.2, 0.5)

      t("operator.settings.imports.invalid_observation_duplicate_max_distance")
    end

    # Validates the subfolder filter entry by entry (PR-0 §0.2) and stores the entries relative to
    # the scan root. A blank filter is allowed (the whole home, minus the denylist); a folder that
    # doesn't exist yet is saved and shown as missing.
    def validate_project_scans_settings(settings)
      return nil unless settings.key?("project_scan_subfolders")

      roots = ScanRootPolicy.hard_roots.filter_map { |root| root[:path] unless root[:error] }
      entries = ScanRootPolicy::Subfolders.parse(settings["project_scan_subfolders"], hard_roots: roots)
      errors = entries.select { |entry| entry[:error] }.map { |entry| "#{entry[:input]} #{entry[:error]}" }
      return t("operator.settings.project_scans.invalid_subfolders", errors: errors.join("; ")) if errors.any?

      settings["project_scan_subfolders"] = ScanRootPolicy::Subfolders.join(entries.map { |entry| entry[:path] })
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
      when :float
        value.to_f
      else
        str = value.to_s
        str = str.strip if key == "summary_model"
        str
      end
    end
  end
end
