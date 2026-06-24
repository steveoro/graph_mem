# frozen_string_literal: true

module DashboardHelper
  STATUS_BADGE_CLASSES = {
    "running" => "dashboard-badge--running",
    "paused" => "dashboard-badge--paused",
    "completed" => "dashboard-badge--completed",
    "failed" => "dashboard-badge--failed",
    "idle" => "dashboard-badge--idle"
  }.freeze

  def dashboard_status_badge(status)
    css = STATUS_BADGE_CLASSES[status.to_s] || "dashboard-badge--idle"
    content_tag(:span, status.to_s.humanize, class: "dashboard-badge #{css}")
  end

  def dashboard_stat_chip(label, value)
    content_tag(:div, class: "dashboard-stat-chip") do
      safe_join([
        content_tag(:span, value, class: "dashboard-stat-chip__value"),
        content_tag(:span, label, class: "dashboard-stat-chip__label")
      ])
    end
  end

  def compaction_phase_label(phase)
    case phase.to_s
    when "orphans" then "Orphan parenting"
    when "tree_walk" then "Tree walk compaction"
    else phase.to_s.humanize
    end
  end

  def compaction_phases
    CompactionRun::PHASES
  end

  def phase_active?(current_phase, phase)
    current_phase.to_s == phase.to_s
  end

  def phase_complete?(current_phase, phase, dream_state)
    return false if dream_state.to_s.in?(%w[idle running paused])

    idx = compaction_phases.index(phase.to_s)
    current_idx = compaction_phases.index(current_phase.to_s)
    return false unless idx && current_idx

    dream_state.to_s == "completed" || current_idx > idx
  end

  def compaction_running?(compaction)
    compaction[:dream_state].to_s == "running"
  end

  def compaction_pausable?(compaction)
    compaction_running?(compaction)
  end

  def compaction_resumable?(compaction)
    state = compaction[:dream_state].to_s
    state.in?(%w[paused completed failed idle])
  end

  def format_dashboard_time(time)
    return "—" if time.blank?

    time = Time.zone.parse(time.to_s) if time.is_a?(String)
    l(time, format: :short)
  rescue ArgumentError
    time.to_s
  end

  def compaction_duration(compaction)
    started = compaction[:started_at]
    finished = compaction[:finished_at]
    return "—" if started.blank?

    start_time = Time.zone.parse(started.to_s)
    end_time = finished.present? ? Time.zone.parse(finished.to_s) : Time.current
    distance = ((end_time - start_time) / 60).round
    "#{distance} min"
  rescue ArgumentError
    "—"
  end
end
