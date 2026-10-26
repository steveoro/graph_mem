# frozen_string_literal: true

# Turns review service results into responses for ReviewController (UI-5b C2), with the same
# statuses as ChangesController: 200 on success (303 redirect for HTML), 404 for a missing row,
# 409 for a group that changed since its preview, 422 for a refused action, 503 when the
# membership lock is busy or the database reports a transient lock error. The toast offers Undo
# when the action's change set can be undone, and says why when it can't.
module ReviewResponses
  extend ActiveSupport::Concern

  NOT_UNDOABLE = {
    "hard_delete" => "entity deleted", "mixed_merge" => "merge mixed with other writes",
    "audit_incomplete" => "the audit trail is incomplete", "snapshot_too_large" => "too large to snapshot"
  }.freeze

  included do
    rescue_from ProjectMembership::LockTimeout, with: :review_busy
    rescue_from ActiveRecord::StatementInvalid, with: :review_statement_error
  end

  private

  # @param result [Hash] a CompactionReviewService / ReviewGroupActions result
  # @param remove [Array<String>] DOM ids to remove on success (the acted-on row or group)
  def respond_with_review(result, remove: [])
    kind = result[:success] ? :notice : :alert
    message = review_message(result)
    undo = review_undo(result)
    return review_redirect(kind, message, undo) if params[:return_to] == "dashboard"

    respond_to do |format|
      format.turbo_stream do
        flash.now[kind] = message
        flash.now[:undo] = undo if undo
        streams = [ turbo_stream.update("toasts", partial: "layouts/flash_messages") ]
        streams += remove.map { |id| turbo_stream.remove(id) } if result[:success]
        render turbo_stream: streams, status: review_status(result)
      end
      format.html { review_redirect(kind, message, undo) }
    end
  end

  # 303 back (Turbo follows it): the dashboard's scan card, or HTML requests.
  def review_redirect(kind, message, undo)
    flash[kind] = message
    flash[:undo] = undo if undo
    redirect_to review_return_path, status: :see_other
  end

  def review_status(result)
    return :ok if result[:success]
    return :conflict if result[:status] == :conflict
    return :not_found if result[:error].to_s.match?(/not found/i)

    :unprocessable_content
  end

  def review_message(result)
    return t("ui.review.not_found") if review_status(result) == :not_found
    return [ result[:error], t("ui.review.review_again") ].join(". ") if result[:status] == :conflict
    return result[:error].to_s unless result[:success]

    reason = result[:change_set_uuid] && !result[:undoable] ? NOT_UNDOABLE.fetch(result[:not_undoable_reason].to_s, "not undoable") : nil
    reason ? "#{result[:message]} (#{t('ui.review.cant_undo', reason: reason)})" : result[:message].to_s
  end

  def review_undo(result)
    return unless result[:success] && result[:undoable] && result[:change_set_uuid]

    { "uuid" => result[:change_set_uuid], "label" => result[:message].to_s }
  end

  # Back to the page the action came from: a review page, or the dashboard's scan card.
  def review_return_path
    back = params[:return_to].to_s
    return root_path if back == "dashboard"

    back.start_with?("/review") && !back.start_with?("//") ? back : review_path
  end

  def review_busy(_error = nil)
    respond_with_status(t("ui.changes.busy"), :service_unavailable)
  end

  def review_statement_error(error)
    raise error unless TransientDbError.busy?(error)

    review_busy
  end

  def respond_with_status(message, status)
    respond_to do |format|
      format.turbo_stream do
        flash.now[:alert] = message
        render turbo_stream: turbo_stream.update("toasts", partial: "layouts/flash_messages"), status: status
      end
      format.html do
        flash[:alert] = message
        redirect_to review_return_path, status: :see_other
      end
      format.any { head status }
    end
  end
end
