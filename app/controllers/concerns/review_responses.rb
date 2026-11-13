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
  # @param refresh [MaintenanceReportRow, nil] the acted-on row (1.86.2): on success the detail pane
  #   shows the done state and the row's group card shows its new counts (or goes once it's empty)
  # @param rail [Boolean] on success, also send the rail's per-badge counts
  # @yieldreturn [Array<String>] more Turbo Streams to send on success (Turbo Stream answers only)
  def respond_with_review(result, remove: [], refresh: nil, rail: refresh.present?)
    return review_frame_not_found if request.get? && review_status(result) == :not_found

    kind = result[:success] ? :notice : :alert
    message = review_message(result)
    undo = review_undo(result)

    respond_to do |format|
      format.turbo_stream do
        flash.now[kind] = message
        flash.now[:undo] = undo if undo
        streams = [ turbo_stream.update("toasts", partial: "layouts/flash_messages") ]
        if result[:success]
          streams += remove.map { |id| turbo_stream.remove(id) }
          streams += review_refresh_streams(refresh) if refresh
          streams += review_rail_streams if rail
          streams += Array(yield) if block_given?
        end
        render turbo_stream: streams, status: review_status(result)
      end
      format.html { review_redirect(kind, message, undo) }
    end
  end

  # The detail pane's done state and the row's group card, re-read after the action: the card's
  # counts when the group survives (a whole-card replace would close its open row list), else the
  # card goes.
  # @param row [MaintenanceReportRow]
  # @return [Array<String>] Turbo Streams
  def review_refresh_streams(row)
    key = row.group_key || "#{row.kind}|row:#{row.row_uuid}" # the fallback of ReviewDigest::GROUP_SQL
    dom = helpers.review_group_dom_id(key)
    group = ReviewDigest.new.group_for(key)
    [
      turbo_stream.update("review-detail", partial: "review/detail_done"),
      group ? turbo_stream.update("#{dom}-meta", partial: "review/group_meta", locals: { group: group }) : turbo_stream.remove(dom)
    ]
  end

  # The rail's counted views (Needs attention, By kind, Errors, Scan review).
  # @param digest [ReviewDigest]
  # @return [Hash{String => Integer}]
  def review_rail_counts(digest = ReviewDigest.new)
    active = MaintenanceReportRow.active.where(report_type: ReviewDigest::REPORT_TYPES)
    {
      "attention" => digest.attention_count,
      "errors" => active.where(kind: ReviewRowClassifier::ERROR_KINDS).count,
      "scan" => active.where(report_type: "scan_review").count,
      "kind" => active.count
    }
  end

  # One replace per rail badge (#review-rail-count-<key>), so the nav, its aria-current and an
  # open <details> stay as they are.
  # @return [Array<String>] Turbo Streams
  def review_rail_streams(counts = review_rail_counts)
    counts.map do |key, count|
      turbo_stream.replace("review-rail-count-#{key}", partial: "review/rail_count", locals: { key: key, count: count })
    end
  end

  # 303 back (Turbo follows it), for HTML requests.
  def review_redirect(kind, message, undo)
    flash[kind] = message
    flash[:undo] = undo if undo
    redirect_to review_return_path, status: :see_other
  end

  def review_status(result)
    return :ok if result[:success]
    return :conflict if result[:status] == :conflict
    return :not_found if result[:status] == :not_found || result[:error] == "Suggestion not found"

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

  # Back to the review page the action came from, or /review.
  def review_return_path
    back = params[:return_to].to_s
    back.start_with?("/review") && !back.start_with?("//") ? back : review_path
  end

  # A frame GET (detail, preview) for a missing row: the message in that frame, with 404.
  def review_frame_not_found
    frame = request.headers["Turbo-Frame"].presence || "review-detail"
    render html: helpers.turbo_frame_tag(frame) { helpers.tag.p(t("ui.review.not_found"), class: "ui-muted", data: { testid: "review-not-found" }) },
           status: :not_found
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
