# frozen_string_literal: true

# Scans a project root on disk, extracts structured project knowledge via an LLM,
# and reconciles it with the graph. Destructive changes are queued as
# `scan_review` maintenance rows rather than applied immediately.
#
# A final validation pass checks the existing project subtree (excluding entities
# created by this scan) for observations and relations that look mis-assigned, and
# either repairs them automatically when the target is unambiguous or queues a
# `scan_review` item for operator/agent review.
class ProjectScanner
  DEFAULT_FILE_GLOBS = %w[
    README*
    package.json
    Gemfile
    pyproject.toml
    requirements*.txt
    docker-compose*.yml
    docker-compose*.yaml
    Cargo.toml
    go.mod
    .devin/blueprint.yaml
    docs/**/*.md
  ].freeze
  # Never read, whatever the globs: plans describe work that hasn't happened yet, so a scan
  # would store them as fact.
  EXCLUDED_FILE_GLOBS = %w[docs/plans/**/*].freeze
  MAX_FILES = 50
  MAX_FILE_BYTES = 50_000
  MAX_TOTAL_INPUT_BYTES = 200_000
  SUMMARY_PROVIDER = "ollama"

  Result = Struct.new(
    :success,
    :status,
    :message,
    :project_entity,
    :entities_created,
    :entities_updated,
    :observations_created,
    :observations_obsoleted,
    :observations_moved,
    :relations_created,
    :relations_deleted,
    :entities_reparented,
    :scan_review_items,
    :dismissed_compaction_items,
    :errors,
    :fallback,
    :fallback_reason,
    :skipped_outside_root,
    :skipped_denylisted,
    :parts_total,
    :parts_failed,
    :files_too_large,
    :files_over_budget,
    :partial,
    keyword_init: true
  ) do
    def initialize(success: true, status: "completed", message: nil, **kwargs)
      super(success: success, status: status, message: message, **kwargs)
    end

    def to_h
      {
        success: success,
        status: status,
        message: message,
        project_entity_id: project_entity&.id,
        project_entity_name: project_entity&.name,
        entities_created: entities_created || 0,
        entities_updated: entities_updated || 0,
        observations_created: observations_created || 0,
        observations_obsoleted: observations_obsoleted || 0,
        observations_moved: observations_moved || 0,
        relations_created: relations_created || 0,
        relations_deleted: relations_deleted || 0,
        entities_reparented: entities_reparented || 0,
        scan_review_items: scan_review_items || [],
        dismissed_compaction_items: dismissed_compaction_items || 0,
        errors: errors || [],
        fallback: fallback || false,
        fallback_reason: fallback_reason,
        skipped_outside_root: skipped_outside_root || 0,
        skipped_denylisted: skipped_denylisted || 0,
        parts_total: parts_total || 0,
        parts_failed: parts_failed || 0,
        files_too_large: files_too_large || 0,
        files_over_budget: files_over_budget || 0,
        partial: partial || false
      }
    end
  end

  def initialize(project_root:, project_name: nil, aliases: nil, mode: "initial",
                 dry_run: false, file_globs: nil, operation_progress: nil,
                 max_files: nil, max_total_input_bytes: nil, scan_id: nil)
    @project_root = File.expand_path(project_root.to_s)
    @project_name = project_name.to_s.strip.presence
    @aliases = Array(aliases).flat_map { |a| a.to_s.split(/[,|;]/).map(&:strip) }.reject(&:blank?)
    @mode = mode.to_s.downcase
    @dry_run = dry_run == true
    @file_globs = Array(file_globs).presence || DEFAULT_FILE_GLOBS
    @operation_progress = operation_progress
    @max_files = (max_files || MAX_FILES).to_i
    @max_total_input_bytes = (max_total_input_bytes || MAX_TOTAL_INPUT_BYTES).to_i
    @scan_id = scan_id || SecureRandom.uuid
    @logger = Rails.logger
    @entities_by_path = {}
    @created_entity_ids = Set.new
    @scan_review_items = []
    @errors = []
    @dismissed_compaction_items = 0
    @project_entity = nil
    @context_text = ""
    @extracted_data = {}
    @created_count = 0
    @updated_count = 0
    @observations_created_count = 0
    @observations_obsoleted_count = 0
    @relations_created_count = 0
    @observations_moved_count = 0
    @relations_deleted_count = 0
    @entities_reparented_count = 0
    @validation_paused = false
    @extraction = {}
    @file_filter = ProjectScanFileFilter.new(@project_root)
  end

  def call
    unless Dir.exist?(@project_root)
      return failed_result("Project root does not exist: #{@project_root}")
    end

    if @mode == "validate"
      return run_validation_only
    end

    if (bad_glob = @file_filter.invalid_glob(@file_globs))
      return failed_result("file_globs entry #{bad_glob.inspect} must be relative to the project root, without '..'")
    end

    update_progress!(phase: "discovering_files", message: "Discovering project files")
    @discovered_files = discover_files
    return failed_result("No readable files found in project root") if @discovered_files.empty?

    update_progress!(phase: "reading_files", message: "Reading #{@discovered_files.size} project files")
    update_progress!(phase: "extracting_knowledge", message: "Extracting knowledge")
    extracted = extract_knowledge
    @extracted_data = extracted[:data] || {}

    update_progress!(phase: "reconciling_graph", message: "Reconciling with graph memory")
    reconcile(@extracted_data)

    unless @dry_run
      validate_project_subtree!
      seed_scan_review_items!
    end

    if @validation_paused
      update_progress!(phase: "validation_paused", message: "Project scan validation paused for next batch")
      return scan_result(extracted, status: "paused", message: "Project scan validation paused for next batch")
    end

    update_progress!(phase: "completed", message: "Project scan completed")
    scan_result(extracted)
  end

  private

  include LlmExtraction
  include DeterministicExtraction

  # Files the scan skipped because they left the root or are denylisted (ProjectScanFileFilter).
  def skip_counters
    @file_filter.counters.transform_keys(&:to_sym)
  end

  def scan_result(extracted, status: "completed", message: nil)
    Result.new(
      success: @errors.empty?,
      status: status,
      message: message,
      project_entity: @project_entity,
      entities_created: @created_count,
      entities_updated: @updated_count,
      observations_created: @observations_created_count,
      observations_obsoleted: @observations_obsoleted_count,
      observations_moved: @observations_moved_count,
      relations_created: @relations_created_count,
      relations_deleted: @relations_deleted_count,
      entities_reparented: @entities_reparented_count,
      scan_review_items: @scan_review_items,
      dismissed_compaction_items: @dismissed_compaction_items,
      errors: @errors,
      fallback: extracted[:fallback] == true,
      fallback_reason: extracted[:fallback_reason],
      partial: partial?,
      **skip_counters,
      **@extraction.slice("parts_total", "parts_failed", "files_too_large", "files_over_budget").transform_keys(&:to_sym)
    )
  end

  def failed_result(message)
    @errors << message
    Result.new(success: false, status: "failed", errors: @errors, fallback: false)
  end

  def scan_source(phase = "reconcile")
    "project_scan:#{@scan_id}:#{phase}"
  end

  def run_validation_only
    unless @project_name.present?
      return failed_result("project_name is required for validate mode")
    end

    update_progress!(phase: "resolving_project", message: "Resolving project root for validation")
    @project_entity = MemoryEntity.find_by(name: @project_name, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
    @project_entity ||= MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).find { |e|
      (e.aliases.to_s.split(/[,|;]/).map(&:strip).map(&:downcase) & [ @project_name.to_s.downcase ]).any?
    }

    return failed_result("Project entity not found: #{@project_name}") unless @project_entity

    unless @dry_run
      validate_project_subtree!
      seed_scan_review_items!
    end

    if @validation_paused
      update_progress!(
        phase: "validation_paused",
        message: "Project validation paused for next batch"
      )

      return Result.new(
        success: @errors.empty?,
        status: "paused",
        message: "Project validation paused for next batch",
        project_entity: @project_entity,
        entities_created: 0,
        entities_updated: 0,
        observations_created: 0,
        observations_obsoleted: @observations_obsoleted_count,
        observations_moved: @observations_moved_count,
        relations_created: 0,
        relations_deleted: @relations_deleted_count,
        entities_reparented: @entities_reparented_count,
        scan_review_items: @scan_review_items,
        dismissed_compaction_items: 0,
        errors: @errors,
        fallback: false,
        fallback_reason: nil
      )
    end

    update_progress!(phase: "completed", message: "Project validation completed (#{@dry_run ? 'dry run' : 'applied'})")

    Result.new(
      success: @errors.empty?,
      project_entity: @project_entity,
      entities_created: 0,
      entities_updated: 0,
      observations_created: 0,
      observations_obsoleted: @observations_obsoleted_count,
      observations_moved: @observations_moved_count,
      relations_created: 0,
      relations_deleted: @relations_deleted_count,
      entities_reparented: @entities_reparented_count,
      scan_review_items: @scan_review_items,
      dismissed_compaction_items: 0,
      errors: @errors,
      fallback: false,
      fallback_reason: nil
    )
  end

  # Globs under the root, keeping only files inside it that aren't denylisted (PR-0 §0.5) or
  # excluded (EXCLUDED_FILE_GLOBS), sorted before the max_files cap so the selected set doesn't depend on filesystem order.
  # Returns the realpaths that were checked, so the read can't follow a different link.
  def discover_files
    glob_files = readable_files(@file_globs.flat_map { |g| @file_filter.glob(g) })

    # If explicit globs produce nothing, fall back to a shallow source scan.
    glob_files = readable_files(@file_filter.glob("**/*").select { |f| text_extension?(f) }) if glob_files.empty?

    glob_files.sort.first(@max_files)
  end

  def readable_files(paths)
    paths.uniq.filter_map do |path|
      next unless File.file?(path)

      real = @file_filter.kept_path(path)
      real if real && !excluded_file?(real) && File.readable?(real) && !binary?(real)
    end.uniq
  end

  def excluded_file?(path)
    relative = Pathname.new(path).relative_path_from(@file_filter.root).to_s
    EXCLUDED_FILE_GLOBS.any? { |glob| File.fnmatch?(glob, relative, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
  end

  def binary?(path)
    File.open(path, "rb") do |file|
      chunk = file.read(4096)
      return false if chunk.nil? || chunk.empty?

      chunk.include?("\0")
    end
  end

  def text_extension?(path)
    ext = File.extname(path).downcase
    %w[.rb .py .js .ts .jsx .tsx .java .go .rs .c .cpp .h .hpp .md .txt .yml .yaml .json .toml .sh .dockerfile .haml .html .css .scss].include?(ext) ||
      File.basename(path).downcase == "gemfile" ||
      File.basename(path).downcase == "dockerfile"
  end

  def reconcile(data)
    project_data = data&.dig("project") || {}
    architecture = data&.dig("architecture") || []

    ActiveRecord::Base.transaction do
      @project_entity = reconcile_project_root(project_data)
      return if @project_entity.nil? && !@dry_run

      # Two passes: every entity first, then every relation, so a relation to an entity listed
      # later (or in another part) resolves.
      reconciled = architecture.filter_map { |item| reconcile_architecture_item(item) }
      reconciled.each { |entity, item| Array(item["relations"]).each { |rel| reconcile_relation(entity, rel) } }

      mark_missing_entities unless @dry_run
      dismiss_conflicting_compaction_reviews unless @dry_run
    end
  rescue StandardError => e
    @logger.error "ProjectScanner: reconciliation failed: #{e.message}"
    @errors << "Reconciliation failed: #{e.message}"
    raise ActiveRecord::Rollback
  end

  def reconcile_project_root(project_data)
    name = @project_name.presence || project_data["name"].to_s.strip.presence || File.basename(@project_root)
    description = project_data["description"].to_s.strip.presence
    aliases = (@aliases + Array(project_data["aliases"])).uniq

    candidates = ([ name ] + aliases).map(&:to_s).reject(&:blank?)
    entity = MemoryEntity.find_by(name: candidates, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE) ||
             MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).find { |e|
               (e.aliases.to_s.split(/[,|;]/).map(&:strip).map(&:downcase) & candidates.map(&:downcase)).any?
             }

    if entity
      unless @dry_run
        updates = {}
        updates[:description] = description if description.present? && entity.description.blank?
        updates[:aliases] = (Array(entity.aliases).flat_map { |a| a.to_s.split(/[,|;]/) } + aliases).uniq.join(",") if aliases.any?
        entity.update!(updates) if updates.any?
        @updated_count += 1 if updates.any?
      end
      entity
    else
      return nil if @dry_run

      entity = MemoryEntity.create!(
        name: name,
        entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE,
        aliases: aliases.any? ? aliases.join(",") : nil,
        description: description
      )
      @created_count += 1
      entity
    end
  rescue StandardError => e
    @errors << "Failed to reconcile project root: #{e.message}"
    nil
  end

  # @return [Array(MemoryEntity, Hash), nil] the entity and its item, for the relation pass
  def reconcile_architecture_item(item)
    entity_data = item["entity"] || {}
    name = entity_data["name"].to_s.strip
    type = ImportEntityResolver.canonical_type(entity_data["type"])
    return if name.blank? || type.blank?

    entity = find_or_create_entity(name, type, entity_data)
    return unless entity

    @entities_by_path[name.downcase] = entity
    @entities_by_path["#{name.downcase}:#{type.downcase}"] = entity

    import_observations(entity, Array(item["observations"]))
    [ entity, item ]
  end

  def find_or_create_entity(name, type, entity_data)
    existing = MemoryEntity.find_by(name: name, entity_type: type, project_id: @project_entity&.id)
    if existing
      unless @dry_run
        updates = {}
        updates[:description] = entity_data["description"].to_s.strip if entity_data["description"].to_s.strip.present? && existing.description.blank?
        aliases = Array(entity_data["aliases"]).map(&:to_s).map(&:strip).reject(&:blank?)
        if aliases.any?
          merged = (Array(existing.aliases).flat_map { |a| a.to_s.split(/[,|;]/) } + aliases).uniq.join(",")
          updates[:aliases] = merged
        end
        if updates.any?
          existing.update!(updates)
          @updated_count += 1
        end
      end
      return existing
    end

    return nil if @dry_run

    entity = MemoryEntity.create!(
      name: name,
      entity_type: type,
      project_id: @project_entity&.id,
      aliases: Array(entity_data["aliases"]).map(&:to_s).map(&:strip).reject(&:blank?).join(",").presence,
      description: entity_data["description"].to_s.strip.presence
    )
    @created_count += 1
    @created_entity_ids << entity.id
    entity
  rescue StandardError => e
    @errors << "Failed to create/update entity #{name}: #{e.message}"
    nil
  end

  def import_observations(entity, observations)
    existing_contents = entity.active_memory_observations.pluck(:content).map(&:to_s).map(&:strip).to_set
    observations.each do |content|
      text = content.to_s.strip
      next if text.blank? || existing_contents.include?(text)

      next if @dry_run

      MemoryObservation.create!(
        memory_entity: entity,
        content: text,
        source: scan_source("reconcile"),
        confidence: 0.9
      )
      @observations_created_count += 1
      existing_contents.add(text)
    end
  rescue StandardError => e
    @errors << "Failed to add observation to #{entity.name}: #{e.message}"
  end

  def reconcile_relation(from_entity, rel)
    target_name = rel["to"].to_s.strip
    relation_type = rel["type"].to_s.strip
    return if target_name.blank? || relation_type.blank?

    target = resolve_relation_target(target_name)
    return unless target
    return if from_entity.id == target.id

    relation_type = MemoryRelation.canonical_relation_type(relation_type)
    return if relation_exists?(from_entity, target, relation_type)

    return if @dry_run

    MemoryRelation.create!(
      from_entity_id: from_entity.id,
      to_entity_id: target.id,
      relation_type: relation_type,
      confidence: rel["confidence"].to_f.clamp(0.0, 1.0).presence,
      properties: { source: scan_source("reconcile"), scan_id: @scan_id }
    )
    if relation_type == "part_of"
      begin
        ProjectMembership.sync!(from_entity)
      rescue ProjectMembership::Collision => e
        @errors << "Project scope conflict for #{from_entity.name}: #{e.message}"
      end
    end
    @relations_created_count += 1
  rescue StandardError => e
    @errors << "Failed to create relation #{from_entity.name} -> #{target_name}: #{e.message}"
  end

  def resolve_relation_target(name)
    return @project_entity if @project_entity && (name.casecmp?(@project_entity.name) || @project_entity.aliases.to_s.split(/[,|;]/).any? { |a| a.strip.casecmp?(name) })

    @entities_by_path[name.downcase] ||
      MemoryEntity.find_by(name: name, project_id: @project_entity&.id) ||
      MemoryEntity.find_by(name: name, project_id: nil) ||
      MemoryEntity.where(project_id: @project_entity&.id).where("aliases LIKE ?", "%#{name}%").first
  end

  def relation_exists?(from, to, relation_type)
    MemoryRelation.exists?(
      from_entity_id: from.id,
      to_entity_id: to.id,
      relation_type: relation_type
    )
  end

  def mark_missing_entities
    return if @project_entity.nil?

    project_entity_ids = ProjectSubtree.resolve(@project_entity.id).entity_ids
    scanned_ids = @entities_by_path.values.map(&:id).uniq

    missing_ids = project_entity_ids - scanned_ids - [ @project_entity.id ]
    return if missing_ids.empty?

    missing_ids.each do |id|
      entity = MemoryEntity.find_by(id: id)
      next unless entity
      next if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

      # Obsolete observations sourced from prior project scan runs.
      entity.active_memory_observations.each do |observation|
        if from_prior_scan?(observation.source)
          observation.mark_obsolete!(reason: "not found in project scan")
          @observations_obsoleted_count += 1
        end
      end

      # Queue entity deletion for review if it has no remaining active observations.
      if entity.active_memory_observations.empty?
        queue_scan_review({
          id: SecureRandom.uuid,
          kind: "delete_entity",
          entity_id: entity.id,
          reason: "Entity not found during project scan of #{@project_root}"
        })
      end
    end
  end

  def from_prior_scan?(source)
    source = source.to_s
    return false if source.include?(@scan_id)

    source.start_with?("project_scan") || source.start_with?("project_scan_skill")
  end

  def validate_project_subtree!
    return if @project_entity.nil?
    return unless AppSettings.project_scan_validation_enabled?

    validator = ProjectScanValidator.new(
      project_entity: @project_entity,
      scan_id: @scan_id,
      created_entity_ids: @created_entity_ids,
      context_text: @context_text,
      extracted_data: @extracted_data,
      project_root: @project_root,
      dry_run: @dry_run,
      logger: @logger,
      operation_progress: @operation_progress
    )

    merge_validation_result(validator.call)
  end

  def merge_validation_result(result)
    @observations_moved_count += result.observations_moved.to_i
    @observations_obsoleted_count += result.observations_obsoleted.to_i
    @relations_deleted_count += result.relations_deleted.to_i
    @entities_reparented_count += result.entities_reparented.to_i
    @scan_review_items.concat(result.scan_review_items || [])
    @errors.concat(result.errors || [])
    @validation_paused = result.paused if result.respond_to?(:paused)
  end

  def dismiss_conflicting_compaction_reviews
    pending = CompactionReviewService.items(report_type: "compaction_review", status: "active", page: 1)
    pending.each do |row|
      next unless conflicts_with_scan?(row)

      result = CompactionReviewService.dismiss(row.row_uuid, reason: "contradicted by project scan", report_type: "compaction_review")
      @dismissed_compaction_items += 1 if result[:success]
    end
  rescue StandardError => e
    @logger.warn "ProjectScanner: failed to dismiss compaction reviews: #{e.message}"
  end

  def conflicts_with_scan?(row)
    payload = row.effective_payload.with_indifferent_access
    entity_ids = case row.kind
    when "entity_merge"
                   [ payload.dig("entity_a", "entity_id"), payload.dig("entity_b", "entity_id") ]
    when "relationship_proposal"
                   [ payload[:from_entity_id], payload[:to_entity_id] ]
    when "orphan_parent"
                   [ payload[:entity_id] ]
    else
                   []
    end
    entity_ids = entity_ids.compact

    scanned_ids = @entities_by_path.values.map(&:id).uniq
    # If the review involves only entities we scanned and proposes a merge/relationship
    # that the scan result contains no relation between the two entity names, it is potentially stale. A conservative rule:
    # dismiss merge suggestions for scanned entities when the scan result contains
    # no relation between the two entity names.
    return false unless entity_ids.all? { |id| scanned_ids.include?(id) }

    if row.kind == "relationship_proposal"
      from = MemoryEntity.find_by(id: payload[:from_entity_id])
      to = MemoryEntity.find_by(id: payload[:to_entity_id])
      return false unless from && to

      return !relation_mentioned_in_scan?(from.name, to.name)
    end

    false
  end

  def relation_mentioned_in_scan?(from_name, to_name)
    # We do not retain the raw scan relation list in memory after reconciliation,
    # but all successfully reconciled relations are in the database.
    scope_ids = [ @project_entity&.id ]
    from = MemoryEntity.find_by(name: from_name, project_id: scope_ids) ||
           MemoryEntity.find_by(name: from_name, project_id: nil)
    to = MemoryEntity.find_by(name: to_name, project_id: scope_ids) ||
         MemoryEntity.find_by(name: to_name, project_id: nil)
    return false unless from && to

    MemoryRelation.exists?(from_entity_id: from.id, to_entity_id: to.id) ||
      MemoryRelation.exists?(from_entity_id: to.id, to_entity_id: from.id)
  end

  def queue_scan_review(item)
    @scan_review_items << item
  end

  def seed_scan_review_items!
    return if @scan_review_items.empty?

    rows = CompactionReviewService.seed_report(
      report_type: "scan_review",
      source: "project_scan:#{@project_root}",
      items: @scan_review_items
    )
    ReviewPolicyJob.enqueue_if_seeded(trigger: "project_scan", seeded: rows)
  end

  def update_progress!(phase:, message:, current: nil, total: nil)
    return unless @operation_progress

    current_value = current || @operation_progress.current_count.to_i + 1
    total_value = total || [ @operation_progress.total_count.to_i, 5 ].max
    @operation_progress.update_progress!(
      current: current_value,
      total: total_value,
      phase: phase,
      message: message,
      counters: {
        entities_created: @created_count,
        entities_updated: @updated_count,
        observations_created: @observations_created_count,
        observations_obsoleted: @observations_obsoleted_count,
        observations_moved: @observations_moved_count,
        relations_created: @relations_created_count,
        relations_deleted: @relations_deleted_count,
        entities_reparented: @entities_reparented_count
      }
    )
    OperationProgressBroadcaster.call(@operation_progress)
  end
end
