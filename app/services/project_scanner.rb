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
  MAX_FILES = 50
  MAX_FILE_BYTES = 50_000
  MAX_TOTAL_INPUT_BYTES = 200_000
  SUMMARY_PROVIDER = "ollama"

  # Relation types that imply the source project actually uses the target.
  USAGE_RELATION_TYPES = %w[
    depends_on
    requires
    used_by
    configured_by
    implements
    extends
    integrates_with
  ].freeze

  Result = Struct.new(
    :success,
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
    keyword_init: true
  ) do
    def to_h
      {
        success: success,
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
        fallback_reason: fallback_reason
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
  end

  def call
    unless Dir.exist?(@project_root)
      return failed_result("Project root does not exist: #{@project_root}")
    end

    if @mode == "validate"
      return run_validation_only
    end

    update_progress!(phase: "discovering_files", message: "Discovering project files")
    @discovered_files = discover_files
    return failed_result("No readable files found in project root") if @discovered_files.empty?

    update_progress!(phase: "reading_files", message: "Reading #{@discovered_files.size} project files")
    @context_text = build_context(@discovered_files)

    update_progress!(phase: "extracting_knowledge", message: "Extracting knowledge")
    extracted = extract_knowledge(@context_text)
    return failed_result("Failed to extract knowledge: #{extracted[:error]}") unless extracted[:ok]

    @extracted_data = extracted[:data] || {}

    update_progress!(phase: "reconciling_graph", message: "Reconciling with graph memory")
    reconcile(@extracted_data)

    unless @dry_run
      validate_project_subtree!
      seed_scan_review_items!
    end

    update_progress!(phase: "completed", message: "Project scan completed")

    Result.new(
      success: @errors.empty?,
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
      fallback_reason: extracted[:fallback_reason] || extracted[:error]
    )
  end

  private

  def failed_result(message)
    @errors << message
    Result.new(success: false, errors: @errors, fallback: false)
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

  def discover_files
    globs = @file_globs.flat_map { |g| Dir.glob(File.join(@project_root, g)) }
    glob_files = globs.select { |f| File.file?(f) && File.readable?(f) && !binary?(f) }

    # If explicit globs produce nothing, fall back to a shallow source scan.
    if glob_files.empty?
      glob_files = Dir.glob(File.join(@project_root, "**", "*"))
                      .select { |f| File.file?(f) && File.readable?(f) && !binary?(f) && text_extension?(f) }
    end

    glob_files.first(@max_files).sort
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

  def build_context(files)
    total = 0
    parts = []

    files.each do |file|
      next if File.size(file) > MAX_FILE_BYTES

      relative = Pathname.new(file).relative_path_from(@project_root).to_s
      content = File.binread(file).force_encoding("UTF-8")
      content = content.encode("UTF-8", invalid: :replace, undef: :replace)
      snippet = "--- FILE: #{relative}\n#{content}\n---\n"

      total += snippet.bytesize
      break if total > @max_total_input_bytes

      parts << snippet
    end

    parts.join("\n")
  end

  def extract_knowledge(context)
    if summarization_disabled_or_unavailable?
      update_progress!(phase: "fallback_extraction", message: "LLM summarization unavailable; using deterministic fallback")
      return { ok: true, data: deterministic_extraction, fallback: true, fallback_reason: "LLM summarization disabled or unavailable" }
    end

    prompt = extraction_prompt(context)
    result = SummaryGenerationClient.generate(prompt, style: "concise")

    unless result[:ok]
      update_progress!(phase: "fallback_extraction", message: "LLM extraction failed; using deterministic fallback")
      return { ok: true, data: deterministic_extraction, fallback: true, fallback_reason: result[:error] }
    end

    data = parse_json(result[:text])
    unless data
      update_progress!(phase: "fallback_extraction", message: "LLM response was not valid JSON; using deterministic fallback")
      return { ok: true, data: deterministic_extraction, fallback: true, fallback_reason: "LLM response was not valid JSON" }
    end

    { ok: true, data: data }
  end

  def extraction_prompt(context)
    <<~PROMPT
      You are a codebase knowledge extractor. Analyze the project files below and produce a single JSON object.

      Required JSON structure:
      {
        "project": {
          "name": "short project name",
          "aliases": ["optional alias 1", "optional alias 2"],
          "description": "one sentence description"
        },
        "architecture": [
          {
            "entity": {
              "name": "entity name",
              "type": "one of: Project, Component, Service, Class, Module, Configuration, Framework, DatabaseTable, APIEndpoint, Route, Migration, TestCase, BestPractice, Preference, Issue, PossibleSolution, Workflow, ApplicationStack, Model, User, Step, Task, Error",
              "aliases": ["..."],
              "description": "..."
            },
            "observations": ["factual statement 1", "factual statement 2"],
            "relations": [
              { "to": "target entity name or project name", "type": "part_of or depends_on or relates_to or implements or extends or configured_by or tested_by", "confidence": 0.9 }
            ]
          }
        ]
      }

      Rules:
      - Only include facts that are directly supported by the file contents.
      - Do not invent files, directories, or entities not mentioned.
      - Use the project root as the top-level parent for "part_of" relations.
      - Keep the response valid JSON only, no markdown.

      Files:
      #{context}
    PROMPT
  end

  def parse_json(text)
    return nil if text.blank?

    text = text.strip
    # Strip a ```json ... ``` fence if present.
    if text.start_with?("```")
      text = text.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\s*\z/m, "")
    end

    JSON.parse(text)
  rescue JSON::ParserError
    nil
  end

  def summarization_disabled_or_unavailable?
    !SummarizationConfig.llm_usable?
  end

  def deterministic_extraction
    project_name = @project_name.presence || project_name_from_readme || File.basename(@project_root)
    description = project_description_from_readme || "Project scanned from #{@project_root} (LLM summarization unavailable)"
    architecture = []

    manifests = @discovered_files.select { |file| manifest_file?(file) }
    manifests.each do |file|
      relative = Pathname.new(file).relative_path_from(@project_root).to_s
      next if relative.blank?

      content_preview = file_preview(file, 400)
      architecture << {
        "entity" => {
          "name" => File.basename(relative),
          "type" => "Configuration",
          "aliases" => [],
          "description" => "Project manifest file: #{relative}"
        },
        "observations" => [
          "Manifest file #{relative} contains: #{content_preview}"
        ],
        "relations" => [
          { "to" => project_name, "type" => "part_of", "confidence" => 0.9 }
        ]
      }
    end

    top_level_directories.each do |dir|
      architecture << {
        "entity" => {
          "name" => dir,
          "type" => "Component",
          "aliases" => [],
          "description" => "Top-level project directory: #{dir}/"
        },
        "observations" => [
          "Top-level directory: #{dir}/"
        ],
        "relations" => [
          { "to" => project_name, "type" => "part_of", "confidence" => 0.9 }
        ]
      }
    end

    {
      "project" => {
        "name" => project_name,
        "aliases" => @aliases,
        "description" => description
      },
      "architecture" => architecture
    }
  end

  def project_name_from_readme
    readme = @discovered_files.find { |file| File.basename(file).downcase.start_with?("readme") }
    return nil unless readme

    content = safe_read(readme)
    content.lines.map(&:strip).find { |line| line =~ /^(#|##)\s+(.+)$/ }&.match(/^(#|##)\s+(.+)$/)&.[](2)
  end

  def project_description_from_readme
    readme = @discovered_files.find { |file| File.basename(file).downcase.start_with?("readme") }
    return nil unless readme

    lines = safe_read(readme).lines.map(&:strip).reject { |line| line.blank? || line.start_with?("#") }
    lines.first(2).join(" ").presence
  end

  def manifest_file?(path)
    name = File.basename(path).downcase
    name == "package.json" ||
      name == "gemfile" ||
      name == "gemfile.lock" ||
      name == "pyproject.toml" ||
      name.start_with?("requirements") ||
      name == "cargo.toml" ||
      name == "go.mod" ||
      name.start_with?("docker-compose") ||
      name == ".devin"
  end

  def top_level_directories
    return [] unless Dir.exist?(@project_root)

    Dir.children(@project_root).select do |child|
      full = File.join(@project_root, child)
      File.directory?(full) && !child.start_with?(".") && child != "node_modules" && child != "vendor"
    end
  rescue SystemCallError
    []
  end

  def file_preview(file, max_bytes)
    text = safe_read(file, max_bytes)
    text.squish.truncate(max_bytes, separator: /\s/)
  end

  def safe_read(file, max_bytes = MAX_FILE_BYTES)
    return "" unless File.readable?(file)

    File.binread(file, [ File.size(file), max_bytes ].min)
      .force_encoding("UTF-8")
      .encode("UTF-8", invalid: :replace, undef: :replace)
  rescue SystemCallError
    ""
  end

  def reconcile(data)
    project_data = data&.dig("project") || {}
    architecture = data&.dig("architecture") || []

    ActiveRecord::Base.transaction do
      @project_entity = reconcile_project_root(project_data)
      return if @project_entity.nil? && !@dry_run

      architecture.each do |item|
        reconcile_architecture_item(item)
      end

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

    Array(item["relations"]).each do |rel|
      reconcile_relation(entity, rel)
    end
  end

  def find_or_create_entity(name, type, entity_data)
    existing = MemoryEntity.find_by(name: name, entity_type: type)
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
    @relations_created_count += 1
  rescue StandardError => e
    @errors << "Failed to create relation #{from_entity.name} -> #{target_name}: #{e.message}"
  end

  def resolve_relation_target(name)
    return @project_entity if @project_entity && (name.casecmp?(@project_entity.name) || @project_entity.aliases.to_s.split(/[,|;]/).any? { |a| a.strip.casecmp?(name) })

    @entities_by_path[name.downcase] ||
      MemoryEntity.find_by(name: name) ||
      MemoryEntity.where("aliases LIKE ?", "%#{name}%").first
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

    update_progress!(phase: "validating_subtree", message: "Validating existing project subtree")
    entity_ids = ProjectSubtree.resolve(@project_entity.id).entity_ids - @created_entity_ids.to_a - [ @project_entity.id ]
    return if entity_ids.empty?

    total = entity_ids.size
    processed = 0
    MemoryEntity.where(id: entity_ids).find_each do |entity|
      validate_entity_observations(entity)
      validate_entity_relations(entity)
      processed += 1
      if (processed % 10).zero? || processed == total
        update_progress!(current: processed, total: total, phase: "validating_subtree", message: "Validated #{processed}/#{total} entities")
      end
    end
  end

  def validate_entity_observations(entity)
    entity.active_memory_observations.find_each do |observation|
      next if observation.source.to_s.include?(@scan_id)
      next unless from_prior_scan?(observation.source)
      next if observation.content.blank?

      action = resolve_observation_action(observation, entity)
      case action[:type]
      when :move
        move_observation_to_entity(observation, action[:target_entity])
      when :obsolete
        mark_observation_obsolete(observation, action[:reason])
      when :review
        queue_scan_review(action[:payload])
      end
    end
  rescue StandardError => e
    @logger.warn "ProjectScanner: failed to validate observations for entity #{entity.id}: #{e.message}"
  end

  def resolve_observation_action(observation, entity)
    content = observation.content.to_s

    if mentions_owned_terms?(content, entity) || mentions_owned_terms?(content, @project_entity)
      return { type: :keep }
    end

    candidates = find_observation_candidates(content, exclude: entity)

    if candidates.size > 1
      best = select_best_candidate(candidates)
      return {
        type: :review,
        payload: {
          id: SecureRandom.uuid,
          kind: "move_observation",
          observation_id: observation.id,
          target_entity_id: best[:entity]&.id,
          reason: "Ambiguous target: observation matches #{candidates.map { |c| "#{c[:entity].name} (#{c[:entity].entity_type})" }.join(', ')}"
        }
      }
    end

    best = select_best_candidate(candidates)

    if best
      return { type: :move, target_entity: best[:entity] }
    end

    # No clear target found; the observation does not reference its owner or
    # project and no matching entity exists. Treat it as mis-assigned and
    # obsolete it with maximum confidence.
    {
      type: :obsolete,
      reason: "Observation does not reference its entity or project and no matching target was found"
    }
  end

  def mentions_owned_terms?(content, owner)
    return false unless owner

    terms = entity_terms(owner)
    terms.any? { |term| content_matches_term?(content, term) }
  end

  def entity_terms(entity)
    terms = [ entity.name.to_s.strip ]
    terms += entity.aliases.to_s.split(/[,|;]/).map(&:strip) if entity.aliases.present?
    terms.map(&:downcase).reject(&:blank?).reject { |t| t.length < 3 }.uniq
  end

  def content_matches_term?(content, term)
    return false if term.blank? || term.length < 3

    words = term.split(/\s+/)
    pattern = words.map { |w| Regexp.escape(w) }.join("\\W+")
    content.to_s.match?(/(?:^|\W)#{pattern}(?:$|\W)/i)
  end

  def find_observation_candidates(content, exclude:)
    candidates = []

    # First pass: search for any entity whose full name/alias appears in the text.
    EntitySearchStrategy.new.search(content, limit: 50).each do |result|
      next if result.entity == exclude

      matched_term = content_matches_entity?(content, result.entity)
      next unless matched_term

      candidates << { entity: result.entity, score: result.score, matched_term: matched_term }
    end

    # Also consider project roots explicitly, because short/generic project names
    # can be missed by token-based search.
    MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).where.not(id: exclude.id).find_each do |project|
      next if project == @project_entity

      matched_term = content_matches_entity?(content, project)
      next unless matched_term

      candidates << { entity: project, score: 0.0, matched_term: matched_term }
    end

    candidates.uniq { |c| c[:entity].id }
  end

  def content_matches_entity?(content, entity)
    entity_terms(entity).find { |term| content_matches_term?(content, term) }
  end

  def select_best_candidate(candidates)
    return nil if candidates.empty?

    candidates.sort_by.with_index do |c, idx|
      # Prefer non-project entities (more specific), then longer matched names,
      # then higher search score, then stable index.
      [
        c[:entity].entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE ? 1 : 0,
        -c[:matched_term].length,
        -c[:score].to_f,
        idx
      ]
    end.first
  end

  def move_observation_to_entity(observation, target_entity)
    return if observation.memory_entity_id == target_entity.id

    ActiveRecord::Base.transaction do
      MemoryObservation.create!(
        memory_entity: target_entity,
        content: observation.content,
        source: scan_source("validation_move"),
        confidence: 1.0
      )
      observation.mark_obsolete!(reason: "Moved to entity #{target_entity.name} (#{target_entity.id}) by project scan validation")
      observation.update!(confidence: 1.0)
    end
    @observations_moved_count += 1
  rescue StandardError => e
    @logger.warn "ProjectScanner: failed to move observation #{observation.id} to #{target_entity.id}: #{e.message}"
    @errors << "Failed to move observation #{observation.id}: #{e.message}"
  end

  def mark_observation_obsolete(observation, reason)
    observation.mark_obsolete!(reason: reason)
    observation.update!(confidence: 1.0)
    @observations_obsoleted_count += 1
  rescue StandardError => e
    @logger.warn "ProjectScanner: failed to obsolete observation #{observation.id}: #{e.message}"
    @errors << "Failed to obsolete observation #{observation.id}: #{e.message}"
  end

  def validate_entity_relations(entity)
    entity.relations_from.find_each do |relation|
      next if relation.properties.to_h["scan_id"] == @scan_id

      if relation.relation_type == "part_of" && wrong_part_of_to_project_root?(relation)
        delete_relation(relation, "part_of to wrong project root")
        next
      end

      if @context_text.present? && usage_relation?(relation) && !relation_target_in_scan_context?(relation.to_entity)
        queue_scan_review({
          id: SecureRandom.uuid,
          kind: "delete_relation",
          relation_id: relation.id,
          reason: "Target #{relation.to_entity&.name} not found in project scan context"
        })
      end
    end
  rescue StandardError => e
    @logger.warn "ProjectScanner: failed to validate relations for entity #{entity.id}: #{e.message}"
  end

  def wrong_part_of_to_project_root?(relation)
    return false unless relation.to_entity

    relation.to_entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE &&
      relation.to_entity_id != @project_entity.id
  end

  def usage_relation?(relation)
    USAGE_RELATION_TYPES.include?(relation.relation_type)
  end

  def relation_target_in_scan_context?(target_entity)
    return true if target_entity.nil?

    terms = entity_terms(target_entity)
    return true if terms.any? { |term| content_matches_term?(@context_text, term) }

    architecture_names.any? { |name| terms.any? { |term| content_matches_term?(name, term) } }
  end

  def architecture_names
    @architecture_names ||= begin
      names = (@extracted_data["architecture"] || []).map { |item| item.dig("entity", "name").to_s }
      names.reject(&:blank?)
    end
  end

  def delete_relation(relation, reason)
    Current.deletion_reason = reason
    relation.destroy!
    @relations_deleted_count += 1
  rescue StandardError => e
    @logger.warn "ProjectScanner: failed to delete relation #{relation.id}: #{e.message}"
    @errors << "Failed to delete relation #{relation.id}: #{e.message}"
  ensure
    Current.deletion_reason = nil
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
    from = MemoryEntity.find_by(name: from_name)
    to = MemoryEntity.find_by(name: to_name)
    return false unless from && to

    MemoryRelation.exists?(from_entity_id: from.id, to_entity_id: to.id) ||
      MemoryRelation.exists?(from_entity_id: to.id, to_entity_id: from.id)
  end

  def queue_scan_review(item)
    @scan_review_items << item
  end

  def seed_scan_review_items!
    return if @scan_review_items.empty?

    CompactionReviewService.seed_report(
      report_type: "scan_review",
      source: "project_scan:#{@project_root}",
      items: @scan_review_items
    )
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
