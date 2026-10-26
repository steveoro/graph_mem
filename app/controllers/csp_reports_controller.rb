# frozen_string_literal: true

# Receives Content-Security-Policy violation reports (CSP enforced since 1.56.0).
# Logs at warn level; rate-limited to prevent log flooding.
class CspReportsController < ActionController::API
  rate_limit to: 100, within: 1.minute

  def create
    payload = request.raw_post.to_s.truncate(500)
    Rails.logger.warn("[CSP] violation report: #{payload}")
    head :no_content
  end
end
