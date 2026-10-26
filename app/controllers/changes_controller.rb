# frozen_string_literal: true

# POST /changes/:uuid/undo (UI-4a): undoes one recorded change set. Operator only (no
# allow_guest), CSRF protected like every ApplicationController form. Turbo Stream requests get
# a toast in #toasts; HTML requests are redirected back with a flash.
class ChangesController < ApplicationController
  STATUSES = {
    ok: :ok, conflict: :conflict, not_undoable: :unprocessable_content,
    not_found: :not_found, busy: :service_unavailable
  }.freeze

  def undo
    result = ChangeSetUndo.call(params[:uuid], actor: Current.actor)
    kind = result.ok? ? :notice : :alert

    respond_to do |format|
      format.turbo_stream do
        flash.now[kind] = toast_message(result)
        render turbo_stream: turbo_stream.update("toasts", partial: "layouts/flash_messages"),
               status: STATUSES.fetch(result.status)
      end
      format.html do
        flash[kind] = toast_message(result)
        redirect_back fallback_location: root_path
      end
    end
  end

  private

  # The service's messages name the change, the window or the refusal reason.
  def toast_message(result)
    case result.status
    when :not_found, :busy then t("ui.changes.#{result.status}")
    when :conflict then t("ui.changes.conflicts", message: result.message, conflicts: result.conflicts.join("; "))
    else result.message
    end
  end
end
