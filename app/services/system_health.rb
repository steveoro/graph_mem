# frozen_string_literal: true

# System › Health (UI-7 S5): Home's health checks (HomeSnapshot::Health, no second probe code)
# plus the embedding probe latency, vector readiness, the Solid Queue backlog, the backup folder,
# each scan root's mount mode, the app version and pending migrations.
#
#   health = SystemHealth.new
#   health.checks   # => [{ key: :database, label: "Database", status: :ok, value: "connected", href: "/system/jobs" }, ...]
#   health.as_json  # => { "version" => "1.63.0", "status" => "ok", "generated_at" => "...", "checks" => [{ "key", "status", "value" }] }
#
# A check's `value` is words only: never a path, URL, host name or setting value, so the JSON
# can't leak one. Paths appear only in `detail`, which the page shows and the JSON leaves out.
class SystemHealth
  include Rails.application.routes.url_helpers

  STATUSES = HomeSnapshot::Health::STATUSES
  # Worst first; :neutral is a choice, not a problem.
  SEVERITY = %i[danger warn ok].freeze

  def initialize(health: HomeSnapshot::Health.new)
    @health = health
  end

  # @return [Array<Hash>] `{ key:, label:, status:, value:, href:, detail: }` per check
  def checks
    @checks ||= [
      @health.pill_for(:database), embeddings_check, vector_check, @health.pill_for(:summaries), queue_check,
      @health.pill_for(:backup), backup_folder_check, scans_check, @health.pill_for(:mcp), @health.pill_for(:guest),
      version_check, migrations_check
    ].map { |check| { detail: nil }.merge(check) }
  end

  # @return [Symbol] the worst status of the checks (:ok when none is a problem)
  def status
    SEVERITY.find { |level| checks.any? { |check| check[:status] == level } } || :ok
  end

  # @return [Hash] the /system/health.json body
  def as_json(*)
    {
      "version" => GraphMem::VERSION, "status" => status.to_s, "generated_at" => Time.current.iso8601,
      "checks" => checks.map { |check| { "key" => check[:key].to_s, "status" => check[:status].to_s, "value" => check[:value] } }
    }
  end

  # The raw snapshots the dashboard used to show (§2.7 "Diagnostics"), for the page only.
  #
  # Each snapshot runs at most once per instance (shared with the checks); one that raises
  # shows as `{ error: "unavailable" }` instead of failing the page.
  #
  # @return [Hash{String => Hash}]
  def raw_snapshots
    {
      "MaintenanceDashboardSnapshot" => snapshot { MaintenanceDashboardSnapshot.call },
      "EmbeddingStatusSnapshot" => snapshot do
        embedding = @health.embedding_status
        embedding.merge(config: embedding[:config].merge(url: without_userinfo(embedding.dig(:config, :url))))
      end,
      "ScanRootPolicy.status" => snapshot { @health.scan_status }
    }
  end

  private

  def snapshot
    yield
  rescue StandardError
    { error: "unavailable" }
  end

  def check(key, status, value, href, detail = nil)
    { key: key, label: I18n.t("system.health.checks.#{key}"), status: status, value: value, href: href, detail: detail }
  end

  def embeddings_check
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    reachable = @health.embedding_reachable?
    latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    return check(:embeddings, :danger, I18n.t("system.health.values.unreachable"), system_embeddings_path) unless reachable

    check(:embeddings, :ok, I18n.t("system.health.values.reachable", ms: latency), system_embeddings_path)
  end

  def vector_check
    ready = @health.embedding_status[:vector_search_ready]
    check(:vector_search, ready ? :ok : :warn, I18n.t("system.health.values.#{ready ? 'vector_ready' : 'vector_not_ready'}"), system_embeddings_path)
  rescue StandardError
    check(:vector_search, :neutral, I18n.t("system.health.values.cant_check"), system_embeddings_path)
  end

  def queue_check
    stats = @health.queue_stats
    return check(:queue, :neutral, I18n.t("home.health.values.unknown"), mission_control_jobs_path) unless stats

    backlog = SolidQueue::ReadyExecution.count
    status = if stats[:failed].positive? then :danger
    elsif stats[:latency] > HomeSnapshot::Health::QUEUE_LATENCY_WARN then :warn
    else :ok
    end
    check(:queue, status, I18n.t("system.health.values.queue", backlog: backlog, failed: stats[:failed]), mission_control_jobs_path)
  rescue StandardError
    check(:queue, :neutral, I18n.t("home.health.values.unknown"), mission_control_jobs_path)
  end

  # Decision 6: no disk-free figure; whether the backup folder is writable (or can be created) instead.
  def backup_folder_check
    writable = BackupFileService.new.folder_writable?
    check(:backup_folder, writable ? :ok : :danger, I18n.t("system.health.values.#{writable ? 'writable' : 'not_writable'}"), system_backups_path)
  rescue StandardError
    check(:backup_folder, :danger, I18n.t("system.health.values.not_writable"), system_backups_path)
  end

  def scans_check
    pill = @health.pill_for(:scans)
    roots = @health.scan_status[:hard_roots].map { |root| { path: root[:path], read_only: root[:read_only], error: root[:error] } }
    pill.merge(value: "#{pill[:value]} · #{I18n.t('system.health.values.roots', count: roots.size)}", detail: roots)
  end

  def version_check
    check(:version, :neutral, GraphMem::VERSION, system_health_path)
  end

  def migrations_check
    pending = ActiveRecord::Base.connection_pool.migration_context.needs_migration?
    check(:migrations, pending ? :danger : :ok, I18n.t("system.health.values.#{pending ? 'migrations_pending' : 'migrations_current'}"), system_health_path)
  rescue StandardError
    check(:migrations, :neutral, I18n.t("system.health.values.cant_check"), system_health_path)
  end

  def without_userinfo(url)
    url.to_s.sub(%r{\A([a-z][a-z0-9+.-]*://)[^/@]*@}i, '\\1')
  end
end
