# frozen_string_literal: true

# Turns an ExploreEdits result into a response for the Explore write controllers (UI-4b W1),
# modelled on ReviewResponses. Turbo Stream: the toast (with Undo for 10 minutes when the change
# set can be undone), the refreshed entity panel, the closed dialog and a `graph_changed` action
# that makes the canvas refetch. HTML: a 303 to Explore with the flash. Statuses: 200, 404 for a
# missing record, 409 for a stale preview, 422 for a refused edit, 503 when the membership lock
# is busy.
module ExploreResponses
  extend ActiveSupport::Concern

  UNDO_TOAST_WINDOW = 10.minutes

  included do
    rescue_from ProjectMembership::LockTimeout, with: :explore_busy
    rescue_from ActiveRecord::RecordNotFound, with: :explore_not_found
  end

  private

  # @param result [Hash] an ExploreEdits result
  # @param entity [MemoryEntity, nil] whose panel to show (nil: leave the panel alone)
  # @param panel_state [Hash] the failed form's values and error, for the panel to re-render
  # @param link [Hash, nil] `{ "href", "label" }` shown in the toast (Propose deletion's review row)
  def respond_with_explore(result, entity:, panel_state: {}, link: nil)
    kind = result[:success] ? :notice : :alert
    message = explore_message(result)
    undo = explore_undo(result)

    respond_to do |format|
      format.turbo_stream do
        flash.now[kind] = message
        flash.now[:undo] = undo if undo
        flash.now[:link] = link if link
        render turbo_stream: explore_streams(result, entity, panel_state), status: result[:status] || :ok
      end
      format.html do
        flash[kind] = message
        flash[:undo] = undo if undo
        flash[:link] = link if link
        redirect_to explore_path(entity_id: entity&.id), status: :see_other
      end
    end
  end

  def explore_streams(result, entity, panel_state)
    streams = [ turbo_stream.update("toasts", partial: "layouts/flash_messages") ]
    entity = MemoryEntity.find_by(id: entity.id) if entity
    if entity
      state = result[:success] ? {} : panel_state.merge(error: result[:error], similar: result[:similar], duplicate_id: result[:duplicate_id])
      streams << turbo_stream.update("entity-panel", partial: "entities/panel", locals: { panel: EntityPanel.new(entity), state: state })
    end
    return streams unless result[:success]

    streams << turbo_stream.update("explore-dialog", "")
    payload = { removed: Array(result[:removed]).map(&:to_s), changed: Array(result[:changed]).map(&:to_s) }
    return streams if payload.values.all?(&:empty?)

    # The payload is read as text by explore_controller.js; escaped, so it can never become markup.
    streams << helpers.turbo_stream_action_tag(:graph_changed, template: ERB::Util.html_escape(payload.to_json))
  end

  def explore_message(result)
    return result[:error].to_s unless result[:success]

    reason = result[:change_set_uuid] && !result[:undoable] ? ReviewResponses::NOT_UNDOABLE.fetch(result[:not_undoable_reason].to_s, "not undoable") : nil
    reason ? "#{result[:message]} (#{t('ui.review.cant_undo', reason: reason)})" : result[:message].to_s
  end

  # Explore's toasts offer Undo for UNDO_TOAST_WINDOW; ChangeSet::WINDOWS still bounds the undo itself.
  def explore_undo(result)
    return unless result[:success] && result[:undoable] && result[:change_set_uuid]

    { "uuid" => result[:change_set_uuid], "label" => result[:message].to_s, "until" => UNDO_TOAST_WINDOW.from_now.iso8601 }
  end

  def explore_busy(_error = nil)
    explore_status_only(t("ui.changes.busy"), :service_unavailable)
  end

  def explore_not_found(_error = nil)
    explore_status_only(t("explore.edits.not_found"), :not_found)
  end

  def explore_status_only(message, status)
    respond_to do |format|
      format.turbo_stream do
        flash.now[:alert] = message
        render turbo_stream: turbo_stream.update("toasts", partial: "layouts/flash_messages"), status: status
      end
      format.html do
        if request.get? && turbo_frame_request?
          render html: helpers.turbo_frame_tag(request.headers["Turbo-Frame"]) { helpers.tag.p(message, class: "ui-muted") }, status: status
        else
          flash[:alert] = message
          redirect_to explore_path, status: :see_other
        end
      end
      format.any { head status }
    end
  end
end
