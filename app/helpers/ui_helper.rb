# frozen_string_literal: true

# Helpers for the application shell (UI-1): role-aware navigation, the page header slot
# and the review-backlog badge. Every `ui-*` class lives in app/assets/tailwind/application.css.
#
# Usage:
#   = ui_nav_link t("ui.nav.search"), search_path, testid: "nav-search", icon: :search
#   - content_for :page_header, ui_page_header("Title", subtitle: "Optional")
module UiHelper
  REVIEW_BACKLOG_CACHE_KEY = "ui/review_backlog_count"

  # Whether to show write controls. Cosmetic only: the server refuses guest writes
  # regardless (RoleAuthorization for HTML, ApiAuthentication for /api/v1).
  #
  # @return [Boolean]
  def can_write?
    operator_signed_in?
  end

  # A sidebar link; the current page gets aria-current="page".
  #
  # @param label [String] visible text (escaped)
  # @param path [String] link target
  # @param testid [String] data-testid value
  # @param icon [Symbol, nil] a DashboardHelper::DASHBOARD_ICONS key
  # @param badge [Integer, nil] count after the label; nothing is rendered for nil or 0
  # @param current [Boolean, nil] overrides current_page?(path) (links that differ only by query)
  # @param data [Hash] extra data attributes, e.g. { turbo: false } for pages outside the shell
  # @return [ActiveSupport::SafeBuffer]
  def ui_nav_link(label, path, testid:, icon: nil, badge: nil, current: nil, data: {})
    current = current_page?(path) if current.nil?
    link_to path, class: "ui-sidebar__link", aria: { current: (current ? "page" : nil) }, data: data.merge(testid: testid) do
      safe_join([
        (dashboard_icon(icon, css_class: "ui-sidebar__icon") if icon),
        tag.span(label, class: "ui-sidebar__label"),
        (tag.span(badge, class: "ui-sidebar__badge", data: { testid: "#{testid}-badge" }) if badge.to_i.positive?)
      ].compact)
    end
  end

  # The page header: one h1, an optional subtitle and an optional actions block.
  #
  # @param title [String]
  # @param subtitle [String, nil]
  # @yield optional actions (buttons, links)
  # @return [ActiveSupport::SafeBuffer]
  def ui_page_header(title, subtitle: nil, &actions)
    render "ui/page_header", title: title, subtitle: subtitle, actions: (capture(&actions) if actions)
  end

  # Review groups needing attention (ReviewDigest), for the sidebar badge. Cached for 30 s; 0
  # without a query for visitors who can't act on reviews.
  #
  # @return [Integer]
  def ui_review_backlog_count
    return 0 unless can_write?

    Rails.cache.fetch(REVIEW_BACKLOG_CACHE_KEY, expires_in: 30.seconds) { ReviewDigest.attention_group_count }
  end
end
