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

  def dashboard_stat_chip_link(label, value, path, **html_options)
    link_to path, class: "dashboard-stat-chip dashboard-stat-chip--link", **html_options.except(:class) do
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

  DASHBOARD_ICONS = {
    search: {
      viewBox: "0 0 24 24",
      paths: [
        "M10.5 3.75a6.75 6.75 0 1 0 0 13.5 6.75 6.75 0 0 0 0-13.5Z",
        "M2.25 10.5a8.25 8.25 0 1 1 14.59 5.28l4.69 4.69a.75.75 0 1 1-1.06 1.06l-4.69-4.69A8.25 8.25 0 0 1 2.25 10.5Z"
      ]
    },
    maintenance: {
      viewBox: "0 0 24 24",
      paths: [
        "M11.42 15.17 17.25 21A2.652 2.652 0 0 0 21 17.25l-5.877-5.877M11.42 15.17l2.496-3.03c.317-.384.74-.626 1.208-.766M11.42 15.17l-4.655 5.653a2.548 2.548 0 1 1-3.586-3.586l6.837-5.63m5.108-.233c.55-.164 1.163-.188 1.743-.14a4.5 4.5 0 0 0 4.486-6.336l-3.276 3.277a3.004 3.004 0 0 1-2.25-2.25l3.276-3.276a4.5 4.5 0 0 0-6.336 4.486c.091 1.076-.071 2.264-.904 2.95l-.102.085m-1.745 1.437L5.909 7.5H4.5L2.25 3.75l1.5-1.5L7.5 4.5v1.409l4.26 4.26m-1.745 1.437 1.745-1.437m6.615 8.206L15.75 15.75M4.867 19.125h.008v.008h-.008v-.008Z"
      ]
    },
    settings: {
      viewBox: "0 0 24 24",
      paths: [
        "M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.593c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z",
        "M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
      ]
    },
    file_choose: {
      viewBox: "0 0 24 24",
      paths: [
        "M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125V5.25c0-1.036-.84-1.875-1.875-1.875h-4.5C5.49 3.375 4.65 4.214 4.65 5.25v13.5c0 1.035.84 1.875 1.875 1.875h9.75c1.035 0 1.875-.84 1.875-1.875v-4.5Z",
        "M12 16.5V9.75m0 0 3 3m-3-3-3 3"
      ]
    }
  }.freeze

  def dashboard_icon(name, css_class: "dashboard-icon")
    icon = DASHBOARD_ICONS.fetch(name.to_sym)

    tag.svg(
      class: css_class,
      xmlns: "http://www.w3.org/2000/svg",
      viewBox: icon[:viewBox],
      fill: "none",
      stroke: "currentColor",
      "stroke-width": "1.5",
      "aria-hidden": "true"
    ) do
      safe_join(icon[:paths].map { |path| tag.path("stroke-linecap": "round", "stroke-linejoin": "round", d: path) })
    end
  end

  def dashboard_topnav_icon_link(path, icon:, label:, testid:)
    link_to path,
      class: "dashboard-topnav__link dashboard-topnav__link--icon",
      title: label,
      aria: { label: label },
      data: { testid: testid } do
      safe_join([
        dashboard_icon(icon, css_class: "dashboard-topnav__icon"),
        content_tag(:span, label, class: "dashboard-sr-only")
      ])
    end
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
