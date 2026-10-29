# frozen_string_literal: true

# Typed confirmation (UI-7, the UI plan §5.2) for backup restore, drop indexes,
# regenerate all embeddings and audit-log prune. The server check is the guard: a missing or
# wrong `params[:confirmation]` → 422 and no side effect, whatever the page's JS did
# (typed_confirm_controller.js only enables the button).
module TypedConfirmation
  extend ActiveSupport::Concern

  private

  # @param expected [String] the text the operator must type (a file name, "DROP", a row count)
  # @return [Boolean] whether `params[:confirmation]` is exactly that text (surrounding spaces ignored)
  def typed_confirmation?(expected)
    expected = expected.to_s
    expected.present? && params[:confirmation].to_s.strip == expected
  end

  # @param action [String] the confirm card that failed (its id)
  # @return [void] sets @confirm_error for the 422 re-render and the alert
  def typed_confirmation_failed!(action)
    @confirm_error = { action => t("system.confirm.mismatch") }
    flash.now[:alert] = t("system.confirm.not_done")
  end
end
