# frozen_string_literal: true

# Review & Fix (UI-5b C2): the grouped review queue for compaction and scan review. Operator only
# (no allow_guest). Lists rank by priority alone (Decision 13); the row and group actions go through
# CompactionReviewService / ReviewGroupActions and answer through ReviewResponses.
class ReviewController < ApplicationController
  include ReviewResponses

  VIEWS = %w[attention kind project errors scan resolved policies].freeze
  REPORT_TYPES = ReviewDigest::REPORT_TYPES
  ROWS_PER_GROUP_PAGE = 20
  EDIT_FIELDS = %i[source_id target_id from_id to_id relation_type node_id parent_id observation_id target_entity_id entity_id].freeze

  before_action :load_row, only: %i[show preview update apply dismiss snooze restore]

  def index
    @view = VIEWS.include?(params[:view]) ? params[:view] : "attention"
    @digest = ReviewDigest.new
    @rail = rail_counts
    @q = params[:q].to_s.strip.presence
    return load_search if @q

    send(:"load_#{@view}")
  end

  # GET /review/group?key= (lazy Turbo Frame): one page of a group's active rows (snoozed ones return when the snooze ends).
  def group
    @key = params.require(:key)
    @rows = MaintenanceReportRow.active.where(report_type: REPORT_TYPES).in_group(@key)
                                .order(priority: :desc, id: :asc).page(params[:page]).per(ROWS_PER_GROUP_PAGE)
    render partial: "review/group", locals: { key: @key, rows: @rows }
  end

  def show
    render partial: "review/detail", locals: { row: @row, preview: CompactionReviewApplier.preview(@row) }
  end

  def preview
    render partial: "review/preview_card",
           locals: { row: @row, preview: CompactionReviewApplier.preview(@row, action_params), keep_id: params[:keep_observation_id] }
  end

  def update
    respond_with_review(CompactionReviewService.edit_item(@row.row_uuid, params.permit(*EDIT_FIELDS), report_type: @row.report_type)
                                               .then { |result| result[:success] ? result.merge(message: t("ui.review.saved")) : result })
  end

  def apply
    respond_with_review(CompactionReviewService.apply(@row.row_uuid, action_params, report_type: @row.report_type), remove: row_ids)
  end

  def dismiss
    respond_with_review(CompactionReviewService.dismiss(@row.row_uuid, reason: params[:reason].presence, report_type: @row.report_type),
                        remove: row_ids)
  end

  def snooze
    respond_with_review(CompactionReviewService.snooze(@row.row_uuid, days: snooze_days, report_type: @row.report_type), remove: row_ids)
  end

  def restore
    respond_with_review(CompactionReviewService.restore(@row.row_uuid, report_type: @row.report_type), remove: row_ids)
  end

  # GET /review/group/preview?key=&op=&min_confidence= : the confirm card for a group action.
  def group_preview
    op = ReviewGroupActions::OPS.include?(params[:op]) ? params[:op] : "dismiss"
    preview = ReviewGroupActions.preview(group_key: params.require(:key), op: op, min_confidence: min_confidence)
    render partial: "review/group_preview_card", locals: { preview: preview }
  end

  def group_apply
    respond_with_review(ReviewGroupActions.apply(group_key: params.require(:key), row_uuids: params[:row_uuids], token: params[:token],
                                                 min_confidence: min_confidence), remove: group_ids)
  end

  def group_dismiss
    respond_with_review(ReviewGroupActions.dismiss(group_key: params.require(:key), row_uuids: params[:row_uuids],
                                                   reason: params[:reason].presence), remove: group_ids)
  end

  def group_snooze
    respond_with_review(ReviewGroupActions.snooze(group_key: params.require(:key), row_uuids: params[:row_uuids], days: snooze_days),
                        remove: group_ids)
  end

  # POST /review/policies/run
  def run_policies
    ReviewPolicyJob.perform_later(trigger: "manual")
    respond_with_review({ success: true, message: t("ui.review.policies_queued") })
  end

  # POST /review/import_suggest_merges (moved from data_exchange): live suggest_merges output → queue.
  def import_suggest_merges
    result = SuggestMergesTool.new.call(threshold: params[:threshold].presence&.to_f, limit: params[:limit].presence&.to_i,
                                        entity_type: params[:entity_type].presence)
    rows = CompactionReviewService.seed_report(
      report_type: "compaction_review", source: "suggest_merges", source_ref: "review/#{Time.current.to_i}",
      items: result[:suggestions].map { |s| { id: SecureRandom.uuid, kind: "entity_merge", **s } }
    )
    respond_with_review({ success: true, message: t("ui.review.imported", count: rows.size) })
  rescue StandardError => e
    Rails.logger.error("import_suggest_merges failed: #{e.class}: #{e.message}")
    respond_with_review({ success: false, error: "Import failed: #{e.message.truncate(200)}" })
  end

  private

  def load_row
    @row = MaintenanceReportRow.where(report_type: REPORT_TYPES).find_by(row_uuid: params[:uuid])
    respond_with_review({ success: false, status: :not_found, error: "Suggestion not found" }) unless @row
  end

  def load_attention
    @groups = @digest.attention
    @below = @digest.below
  end

  def load_kind = load_groups(params[:kind].present? ? active_scope.where(kind: params[:kind]) : active_scope)
  def load_project = load_groups(params[:project_id].present? ? active_scope.where(project_id: params[:project_id]) : active_scope)
  def load_errors = load_groups(active_scope.where(kind: ReviewRowClassifier::ERROR_KINDS))
  def load_scan = load_groups(active_scope.where(report_type: "scan_review"))

  def load_groups(scope)
    @groups = @digest.page(scope, page: params[:page])
    @page = [ params[:page].to_i, 1 ].max
  end

  def load_resolved
    @rows = MaintenanceReportRow.resolved.where(report_type: REPORT_TYPES).order(updated_at: :desc, id: :desc).page(params[:page]).per(25)
    @change_sets = ChangeSet.where(id: @rows.map(&:change_set_id).compact).index_by(&:id)
  end

  def load_policies
    @reports = MaintenanceReport.by_type("review_policy_run").recent.limit(30)
    uuids = @reports.flat_map { |report| Hash(report.data["policies"]).values.flat_map { |stats| Array(Hash(stats)["change_sets"]) } }
    @change_sets = ChangeSet.where(uuid: uuids).index_by(&:uuid)
  end

  # Values-only search over at most SEARCH_SCAN_CAP rows, highest priority first (Decision 8).
  def load_search
    scanned = active_scope.order(priority: :desc, id: :asc).limit(CompactionReviewService::Queries::SEARCH_SCAN_CAP).to_a
    @search_capped = scanned.size == CompactionReviewService::Queries::SEARCH_SCAN_CAP
    @rows = Kaminari.paginate_array(CompactionReviewService.send(:filter_by_query, scanned, @q)).page(params[:page]).per(25)
  end

  def active_scope = MaintenanceReportRow.active.where(report_type: REPORT_TYPES)

  def rail_counts
    {
      "attention" => @digest.attention_count,
      "errors" => active_scope.where(kind: ReviewRowClassifier::ERROR_KINDS).count,
      "scan" => active_scope.where(report_type: "scan_review").count,
      "kind" => active_scope.count
    }
  end

  def action_params = params.permit(*EDIT_FIELDS, :keep_observation_id, :fact_action, :replacement).to_h
  def snooze_days = (params[:days].presence || CompactionReviewService::SNOOZE_DAYS).to_i
  def min_confidence = params[:min_confidence].presence&.to_f
  def row_ids = [ helpers.dom_id(@row) ]
  def group_ids = [ "group-#{Digest::SHA256.hexdigest(params[:key].to_s).first(12)}" ]
end
