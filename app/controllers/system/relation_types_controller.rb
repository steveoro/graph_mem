# frozen_string_literal: true

module System
  # Relation types (R1a), under Background jobs: the sweep's dry run and start ("Canonicalize
  # relation types", RelationTypeSweep / RelationTypeSweepJob), its run reports, and the unmapped
  # types page where the operator maps, accepts or removes `relation_type_mappings` rows
  # (RelationTypeDecision). Operator only, like every System page; nothing here retypes a relation
  # by itself: the sweep does.
  class RelationTypesController < BaseController
    self.nav_section = :jobs

    SCOPE = "system.relation_types"
    CHANGES_PER_PAGE = 100
    MAX_QUERY_LENGTH = 100

    # GET /system/jobs/relation_types: the unmapped types (filtered by `q`) and the mapping rows.
    def index
      @query = params[:q].to_s.strip.first(MAX_QUERY_LENGTH)
      @rows = UnmappedRelationTypes.call(query: @query)
      @mappings = RelationTypeMapping.order(:variant)
      @mappings = @mappings.where("variant LIKE :q OR canonical_type LIKE :q", q: "%#{RelationTypeMapping.sanitize_sql_like(@query)}%") if @query.present?
      @canonical_types = GraphVocabulary::RELATION_TYPES.sort
    end

    # GET /system/jobs/relation_types/sweep: the dry run's counts (synchronous: one read of every
    # relation in batches, a few queries per relation that would change) and the confirm button.
    def preview
      @busy = busy_reason
      @summary = RelationTypeSweep.call(dry_run: true)
    end

    # POST /system/jobs/relation_types/sweep: queues the sweep as the operator.
    def sweep
      busy = busy_reason
      return redirect_to(system_relation_types_sweep_path, alert: t("#{SCOPE}.sweep.#{busy}")) if busy

      RelationTypeSweepJob.perform_later(actor: Current.actor)
      redirect_to system_jobs_path, notice: t("#{SCOPE}.sweep.queued")
    end

    # GET /system/jobs/relation_types/reports/:id: one sweep report, its changes paginated.
    def report
      @report = MaintenanceReport.by_type(RelationTypeSweep::REPORT_TYPE).find(params[:id])
      @changes = Kaminari.paginate_array(@report.data["changes"].to_a).page(params[:page]).per(CHANGES_PER_PAGE)
      ids = @changes.flat_map { |change| change.values_at("from_entity_id", "to_entity_id") }.compact
      @names = MemoryEntity.where(id: ids).pluck(:id, :name).to_h
    end

    # POST /system/jobs/relation_types/map (type, canonical_type)
    def map
      decided(RelationTypeDecision.map(params[:type].to_s, params[:canonical_type].to_s))
    end

    # POST /system/jobs/relation_types/accept (type)
    def accept
      decided(RelationTypeDecision.accept(params[:type].to_s))
    end

    # DELETE /system/jobs/relation_types/mappings/:id
    def destroy_mapping
      decided(RelationTypeDecision.remove(params[:id]))
    end

    private

    # @return [String, nil] why a sweep can't start now ("running", "compaction"), nil when it can
    def busy_reason
      return "running" if RelationTypeSweepJob.running?

      "compaction" if CompactionRun.dream_state_active?
    end

    def decided(result)
      back = system_relation_types_path(q: params[:q].presence)
      message = t("#{SCOPE}.decision.#{result.key}", type: result.type, canonical: result.canonical_type,
                                                     count: result.relations)
      return redirect_to(back, alert: message) unless result.ok

      flash[:link] = { "href" => system_relation_types_sweep_path, "label" => t("#{SCOPE}.sweep.button") } unless result.key.start_with?("removed")
      redirect_to back, notice: message
    end
  end
end
