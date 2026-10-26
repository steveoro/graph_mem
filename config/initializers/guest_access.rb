# frozen_string_literal: true

# Logs once at boot whether the read-only guest account is configured (UI-1). Never logs
# the values, and doesn't read the database (the "Guest access" toggle is checked per request).
Rails.application.config.after_initialize do
  credentials = GraphMem::GuestCredentials.current
  if !credentials.configured?
    Rails.logger.info("[guest access] not configured (no guest password)")
  elsif credentials.collides_with_operator?
    Rails.logger.error("[guest access] disabled: guest username or password equals the operator's")
  else
    Rails.logger.info("[guest access] configured")
  end
end
