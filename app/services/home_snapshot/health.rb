# frozen_string_literal: true

require "net/http"

class HomeSnapshot
  # Home's health strip (§2.2 item 1): one pill per subsystem, each with a status, a short value
  # and the page that explains it. Colour is never the only signal: the value says it in words.
  #
  #   HomeSnapshot::Health.new.pills
  #   # => [{ key: :database, label: "Database", status: :ok, value: "connected", href: "/projects/jobs" }, ...]
  class Health
    include Rails.application.routes.url_helpers

    # :ok (green), :warn (amber), :danger (red), :neutral (a choice, not a problem)
    STATUSES = %i[ok warn danger neutral].freeze
    # The embedding probe is one GET of the service's base URL: any HTTP answer means reachable.
    PROBE_TIMEOUT = 1
    BACKUP_FRESH = 36.hours
    BACKUP_STALE = 7.days
    QUEUE_LATENCY_WARN = 5.minutes

    # Whether the embedding service answers HTTP at +url+ (no embedding is requested). The
    # service boundary: specs stub it (spec/support/home_snapshot_helpers.rb).
    #
    # @param url [String] the service's base URL
    # @return [Boolean]
    def self.embedding_reachable?(url = EmbeddingService.config_snapshot[:url])
      uri = URI(url.to_s)
      return false unless uri.is_a?(URI::HTTP) && uri.host.present?

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: PROBE_TIMEOUT, read_timeout: PROBE_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri.path.presence || "/"))
      end
      true
    rescue StandardError
      false
    end

    # @return [Array<Hash>] `{ key:, label:, status:, value:, href: }` per pill
    def pills
      %i[database embeddings summaries jobs backup scans mcp guest].map { |key| send(:"#{key}_pill") }
    end

    # @return [Boolean] see {.embedding_reachable?}
    def embedding_reachable?
      self.class.embedding_reachable?
    end

    # @return [Hash] `{ failed:, latency: }` (seconds), or nil when the queue can't be read
    def queue_stats
      return nil unless defined?(SolidQueue::FailedExecution) && defined?(SolidQueue::ReadyExecution)

      oldest = SolidQueue::ReadyExecution.minimum(:created_at)
      { failed: SolidQueue::FailedExecution.count, latency: oldest ? (Time.current - oldest).to_i : 0 }
    rescue StandardError
      nil
    end

    # @return [Time, nil] when the newest backup file was written
    def last_backup_at
      BackupFileService.new.list.filter_map { |backup| backup[:modified_at] }.max
    rescue StandardError
      nil
    end

    private

    def pill(key, status, value, href)
      { key: key, label: I18n.t("home.health.#{key}"), status: status, value: value, href: href }
    end

    def database_pill
      ActiveRecord::Base.connection.select_value("SELECT 1")
      pill(:database, :ok, I18n.t("home.health.values.connected"), projects_jobs_path)
    rescue StandardError
      pill(:database, :danger, I18n.t("home.health.values.unreachable"), projects_jobs_path)
    end

    def embeddings_pill
      ready = EmbeddingStatusSnapshot.call[:vector_search_ready]
      status, value =
        if !embedding_reachable? then [ :danger, "unreachable" ]
        elsif ready then [ :ok, "reachable_ready" ]
        else [ :warn, "reachable_not_ready" ]
        end
      pill(:embeddings, status, I18n.t("home.health.values.#{value}"), operator_embeddings_path)
    end

    def summaries_pill
      on = AppSettings.llm_summarization_enabled?
      pill(:summaries, on ? :ok : :neutral, I18n.t("home.health.values.#{on ? 'on' : 'off'}"), operator_settings_path(tab: "summaries"))
    end

    def jobs_pill
      stats = queue_stats
      return pill(:jobs, :neutral, I18n.t("home.health.values.unknown"), "/operator/jobs") unless stats

      status = if stats[:failed].positive? then :danger
      elsif stats[:latency] > QUEUE_LATENCY_WARN then :warn
      else :ok
      end
      value = I18n.t("home.health.values.jobs", failed: stats[:failed], latency: ActiveSupport::Duration.build(stats[:latency]).inspect)
      pill(:jobs, status, value, "/operator/jobs")
    end

    def backup_pill
      at = last_backup_at
      href = operator_settings_path(tab: "database_backup")
      return pill(:backup, :warn, I18n.t("home.health.values.no_backup"), href) unless at

      age = Time.current - at
      status = if age <= BACKUP_FRESH then :ok
      elsif age <= BACKUP_STALE then :warn
      else :danger
      end
      pill(:backup, status, I18n.t("home.health.values.backup_age", age: ActionController::Base.helpers.time_ago_in_words(at)), href)
    end

    def scans_pill
      status = ScanRootPolicy.status
      href = operator_settings_path(tab: "project_scans")
      return pill(:scans, :neutral, I18n.t("home.health.values.scans_off"), href) unless status[:scans_switch]
      return pill(:scans, :danger, I18n.t("home.health.values.nothing_mounted"), href) unless status[:enabled]
      return pill(:scans, :warn, I18n.t("home.health.values.writable"), href) if status[:warnings].include?(:mounted_read_write)

      pill(:scans, :ok, I18n.t("home.health.values.read_only"), href)
    end

    def mcp_pill
      policy = GraphMem::OfficialMcp.access_policy
      pill(:mcp, policy.token_required? ? :ok : :neutral, policy.describe, operator_settings_path(tab: "mcp_access"))
    end

    def guest_pill
      status = GraphMem::GuestCredentials.current.status
      color = { available: :ok, conflict: :danger }.fetch(status, :neutral)
      pill(:guest, color, I18n.t("home.health.values.guest.#{status}"), operator_settings_path(tab: "feature_flags"))
    end
  end
end
