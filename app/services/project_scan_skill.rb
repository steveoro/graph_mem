# frozen_string_literal: true

# Human-guided, multi-stage project scan that runs without an LLM.
# Each call to ProjectScanSkill processes one depth (birds_eye, architecture,
# usage, ui, tests_and_docs), updates the OperationProgress record, and pauses
# so the operator can continue or stop from the dashboard.
class ProjectScanSkill
  DEPTH_ORDER = %w[birds_eye architecture usage ui tests_and_docs].freeze

  DEPTH_LABELS = {
    "birds_eye" => "Birds-eye view",
    "architecture" => "Architecture",
    "usage" => "Usage / configuration",
    "ui" => "UI / routes",
    "tests_and_docs" => "Tests & docs"
  }.freeze

  ARCHITECTURE_DIR_TYPES = {
    "app/controllers" => "Route",
    "app/models" => "Model",
    "app/services" => "Service",
    "app/views" => "Component",
    "app/components" => "Component",
    "app/helpers" => "Service",
    "lib" => "Class",
    "src" => "Component",
    "api" => "APIEndpoint",
    "controllers" => "Route",
    "models" => "Model",
    "services" => "Service",
    "components" => "Component"
  }.freeze

  USAGE_SERVICE_PATTERNS = %w[docker procfile bin ci github gitlab].freeze

  MAX_FILES = 50
  MAX_FILE_BYTES = 50_000

  def self.process!(operation)
    new(operation).process!
  end

  def initialize(operation)
    @operation = operation
    details = operation.details || {}
    @project_root = File.expand_path(details["project_root"].to_s)
    @project_name = details["project_name"].to_s.strip.presence
    @aliases = Array(details["aliases"]).flat_map { |a| a.to_s.split(/[,|;]/).map(&:strip) }.reject(&:blank?)
    @dry_run = details["dry_run"] == true
    @depths = Array(details["depths"]).presence || DEPTH_ORDER
    @current_depth_index = details["current_depth_index"].to_i
    @project_entity = nil
    load_counters
    @errors = []
  end

  def process!
    unless Dir.exist?(@project_root)
      fail!("Project root does not exist: #{@project_root}")
      return result(:failed)
    end

    unless @operation.status == "running"
      @operation.update!(status: "running")
      OperationProgressBroadcaster.call(@operation)
    end

    current_depth = @depths[@current_depth_index]
    if current_depth.nil?
      complete!("Guided scan completed")
      return result(:completed)
    end

    scan_depth(current_depth)

    next_index = @current_depth_index + 1
    if next_index >= @depths.size
      complete!("Guided scan completed", @depths.size)
    else
      pause_for_next_depth(next_index, current_depth)
    end

    result(@operation.status == "paused" ? :paused : :completed)
  rescue StandardError => e
    Rails.logger.error "ProjectScanSkill failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    fail!(e)
    result(:failed)
  end

  def stop!
    previous_index = @current_depth_index.to_i - 1
    depth = previous_index >= 0 ? @depths[previous_index] : nil
    message = depth ? "Stopped by operator after #{DEPTH_LABELS[depth] || depth}" : "Stopped by operator"
    complete!(message, @current_depth_index)
  end

  private

  def load_counters
    existing = (@operation.counters || {}).with_indifferent_access
    @created_count = existing[:entities_created].to_i
    @updated_count = existing[:entities_updated].to_i
    @observations_created_count = existing[:observations_created].to_i
    @relations_created_count = existing[:relations_created].to_i
  end

  def counters
    {
      entities_created: @created_count,
      entities_updated: @updated_count,
      observations_created: @observations_created_count,
      relations_created: @relations_created_count
    }
  end

  def result(status)
    {
      status: status,
      operation_id: @operation.operation_id,
      current_depth_index: @operation.details["current_depth_index"],
      phase: @operation.phase
    }
  end

  def scan_depth(depth)
    send("scan_#{depth}") if respond_to?("scan_#{depth}", true)
  end

  def scan_birds_eye
    ensure_project_entity!
    return unless @project_entity

    manifest_globs = %w[
      README*
      package.json
      Gemfile
      pyproject.toml
      requirements*.txt
      Cargo.toml
      go.mod
      docker-compose*.yml
      docker-compose*.yaml
      .devin/blueprint.yaml
      docs/**/*.md
    ]
    discover_files(manifest_globs).each do |file|
      relative = relative_path(file)
      next if relative.blank?

      entity = find_or_create_child(File.basename(relative), "Configuration", "Project manifest file: #{relative}")
      next unless entity

      preview = file_preview(file, 400)
      add_observation(entity, "Manifest file #{relative} contains: #{preview}", source_for("birds_eye"))
      ensure_part_of(entity, @project_entity)
    end

    top_level_directories.each do |dir|
      entity = find_or_create_child(dir, "Component", "Top-level project directory: #{dir}/")
      next unless entity

      add_observation(entity, "Top-level directory: #{dir}/", source_for("birds_eye"))
      ensure_part_of(entity, @project_entity)
    end
  end

  def scan_architecture
    ensure_project_entity!
    return unless @project_entity

    source_dirs = %w[app/lib app/src app/services app/controllers app/models app/views app/components app/helpers lib src services controllers models components api]
    source_dirs.uniq.each do |dir|
      full_dir = File.join(@project_root, dir)
      next unless Dir.exist?(full_dir)

      parent_type = architecture_type_for(dir)
      Dir.children(full_dir).reject { |c| skip_child?(c) }.each do |child|
        full_child = File.join(full_dir, child)
        name, type = architecture_child_name_and_type(full_child, parent_type, dir)
        next if name.blank?

        entity = find_or_create_child(name, type, "#{type} discovered under #{dir}/: #{child}")
        next unless entity

        add_observation(entity, "#{type} #{child} found in #{dir}/", source_for("architecture"))
        ensure_part_of(entity, @project_entity)
      end
    end
  end

  def scan_usage
    ensure_project_entity!
    return unless @project_entity

    globs = %w[
      config/**/*
      .env*
      docker-compose*.yml
      docker-compose*.yaml
      Dockerfile*
      Procfile
      bin/**/*
      .github/**/*
      .gitlab-ci*
    ]
    discover_files(globs).each do |file|
      relative = relative_path(file)
      type = usage_type_for(relative)
      name = File.basename(relative)
      entity = find_or_create_child(name, type, "#{type} file: #{relative}")
      next unless entity

      preview = file_preview(file, 400)
      add_observation(entity, "#{type} file #{relative}: #{preview}", source_for("usage"))
      ensure_part_of(entity, @project_entity)
    end
  end

  def scan_ui
    ensure_project_entity!
    return unless @project_entity

    globs = %w[
      app/views/**/*
      app/controllers/**/*
      app/helpers/**/*
      frontend/**/*
      config/routes.rb
      config/routes/*
      routes.rb
      pages/**/*
      app/components/**/*
    ]
    discover_files(globs).each do |file|
      relative = relative_path(file)
      type = ui_type_for(relative)
      name = ui_name_for(relative, type)
      next if name.blank?

      entity = find_or_create_child(name, type, "UI element: #{relative}")
      next unless entity

      add_observation(entity, "#{type} discovered: #{relative}", source_for("ui"))
      ensure_part_of(entity, @project_entity)
    end
  end

  def scan_tests_and_docs
    ensure_project_entity!
    return unless @project_entity

    globs = %w[spec/**/* test/**/* docs/**/* README* CHANGELOG* CONTRIBUTING*]
    discover_files(globs).each do |file|
      relative = relative_path(file)
      type = relative.start_with?("spec/", "test/") ? "TestCase" : "Documentation"
      name = File.basename(relative)
      entity = find_or_create_child(name, type, "#{type} resource: #{relative}")
      next unless entity

      preview = file_preview(file, 400)
      add_observation(entity, "#{type} resource #{relative}: #{preview}", source_for("tests_and_docs"))
      ensure_part_of(entity, @project_entity)
    end
  end

  def ensure_project_entity!
    return @project_entity if @project_entity

    project_name = @project_name.presence || project_name_from_readme || File.basename(@project_root)
    description = project_description_from_readme || "Project scanned from #{@project_root} (guided skill)"
    aliases = @aliases

    candidates = ([ project_name ] + aliases).map(&:to_s).reject(&:blank?)
    entity = MemoryEntity.find_by(name: candidates, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE) ||
             MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).find { |e|
               (e.aliases.to_s.split(/[,|;]/).map(&:strip).map(&:downcase) & candidates.map(&:downcase)).any?
             }

    if entity
      unless @dry_run
        updates = {}
        updates[:description] = description if description.present? && entity.description.blank?
        if aliases.any?
          merged = (Array(entity.aliases).flat_map { |a| a.to_s.split(/[,|;]/) } + aliases).uniq.join(",")
          updates[:aliases] = merged
        end
        entity.update!(updates) if updates.any?
        @updated_count += 1 if updates.any?
      end
      @project_entity = entity
    else
      return if @dry_run

      @project_entity = MemoryEntity.create!(
        name: project_name,
        entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE,
        aliases: aliases.any? ? aliases.join(",") : nil,
        description: description
      )
      @created_count += 1
    end
  end

  def find_or_create_child(name, type, description)
    type = ImportEntityResolver.canonical_type(type)
    return nil if name.blank? || type.blank?

    unique_name = unique_name_for(name, type)
    existing = MemoryEntity.find_by(name: unique_name, entity_type: type)
    if existing
      unless @dry_run
        updates = {}
        updates[:description] = description if description.present? && existing.description.blank?
        existing.update!(updates) if updates.any?
        @updated_count += 1 if updates.any?
      end
      existing
    else
      return nil if @dry_run

      entity = MemoryEntity.create!(
        name: unique_name,
        entity_type: type,
        description: description.to_s.strip.presence
      )
      @created_count += 1
      entity
    end
  end

  def unique_name_for(name, type)
    base = name.to_s.strip
    return base unless MemoryEntity.exists?(name: base)
    return base if MemoryEntity.exists?(name: base, entity_type: type)

    suffix = type
    candidate = "#{base} (#{suffix})"
    counter = 2
    while MemoryEntity.exists?(name: candidate)
      candidate = "#{base} (#{suffix} #{counter})"
      counter += 1
    end
    candidate
  end

  def add_observation(entity, content, source)
    return if @dry_run

    text = content.to_s.strip
    return if text.blank?

    existing = entity.active_memory_observations.pluck(:content).map(&:to_s).map(&:strip).to_set
    return if existing.include?(text)

    MemoryObservation.create!(
      memory_entity: entity,
      content: text,
      source: source,
      confidence: 0.9
    )
    @observations_created_count += 1
  end

  def ensure_part_of(child, parent)
    return if @dry_run || child.id == parent.id
    return if MemoryRelation.exists?(from_entity_id: child.id, to_entity_id: parent.id, relation_type: "part_of")

    MemoryRelation.create!(
      from_entity_id: child.id,
      to_entity_id: parent.id,
      relation_type: MemoryRelation.canonical_relation_type("part_of"),
      confidence: 0.9
    )
    @relations_created_count += 1
  end

  def discover_files(globs)
    globs.flat_map do |pattern|
      Dir.glob(File.join(@project_root, pattern)).select { |f| File.file?(f) }
    end.uniq.first(MAX_FILES)
  end

  def top_level_directories
    return [] unless Dir.exist?(@project_root)

    Dir.children(@project_root).select do |child|
      full = File.join(@project_root, child)
      File.directory?(full) && !child.start_with?(".") && !skip_directory?(child)
    end
  rescue SystemCallError
    []
  end

  def skip_directory?(name)
    %w[node_modules vendor tmp log coverage dist build].include?(name)
  end

  def skip_child?(name)
    name.start_with?(".") || name == "node_modules" || name == "vendor"
  end

  def relative_path(file)
    Pathname.new(file).relative_path_from(@project_root).to_s
  rescue ArgumentError
    ""
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

  def project_name_from_readme
    readme = readme_file
    return nil unless readme

    text = safe_read(readme)
    text.lines.map(&:strip).find { |line| line =~ /^(#|##)\s+(.+)$/ }&.match(/^(#|##)\s+(.+)$/)&.[](2)
  end

  def project_description_from_readme
    readme = readme_file
    return nil unless readme

    lines = safe_read(readme).lines.map(&:strip).reject { |line| line.blank? || line.start_with?("#") }
    lines.first(2).join(" ").presence
  end

  def readme_file
    @readme_file ||= discover_files(%w[README*]).first
  end

  def source_for(depth)
    "project_scan_skill:#{depth}:#{@project_root}"
  end

  def architecture_type_for(dir)
    ARCHITECTURE_DIR_TYPES[dir] || "Component"
  end

  def architecture_child_name_and_type(full_child, parent_type, parent_dir)
    child = File.basename(full_child)
    if File.directory?(full_child)
      [ child, "Component" ]
    else
      name = File.basename(child, File.extname(child)).camelize
      type = infer_architecture_file_type(child, parent_type, parent_dir)
      [ name, type ]
    end
  end

  def infer_architecture_file_type(filename, parent_type, parent_dir)
    name = filename.downcase
    return "Route" if name.end_with?("_controller.rb") || parent_dir == "controllers" || parent_dir == "app/controllers"
    return "Model" if name.end_with?(".rb") && (parent_dir == "models" || parent_dir == "app/models")
    return "Service" if name.end_with?(".rb") && (parent_dir == "services" || parent_dir == "app/services")
    return "Class" if parent_dir == "lib" || parent_dir == "src"

    parent_type
  end

  def usage_type_for(relative)
    lowered = relative.downcase
    return "Service" if USAGE_SERVICE_PATTERNS.any? { |p| lowered.include?(p) }

    "Configuration"
  end

  def ui_type_for(relative)
    lowered = relative.downcase
    return "Route" if lowered.include?("controller") || lowered.include?("routes.rb")
    return "Service" if lowered.include?("helper")
    return "APIEndpoint" if lowered.include?("api")

    "Component"
  end

  def ui_name_for(relative, _type)
    File.basename(relative, File.extname(relative)).camelize
  end

  def pause_for_next_depth(next_index, current_depth)
    next_depth = @depths[next_index]
    details = @operation.details.merge(
      "current_depth_index" => next_index,
      "last_completed_depth" => current_depth
    )
    @operation.update_progress!(
      current: next_index,
      total: @depths.size,
      phase: next_depth,
      message: "Paused after #{DEPTH_LABELS[current_depth] || current_depth}. Next: #{DEPTH_LABELS[next_depth] || next_depth}",
      counters: counters,
      details: details
    )
    @operation.pause!(message: "Paused after #{DEPTH_LABELS[current_depth] || current_depth}. Next: #{DEPTH_LABELS[next_depth] || next_depth}")
    OperationProgressBroadcaster.call(@operation)
  end

  def complete!(message, final_index = @current_depth_index)
    final_index = [ final_index, @depths.size ].min
    details = @operation.details.merge(
      "current_depth_index" => final_index,
      "last_completed_depth" => @operation.phase
    )
    @operation.update!(phase: "completed", details: details)
    @operation.complete!(
      message: message,
      counters: counters
    )
    OperationProgressBroadcaster.call(@operation)
  end

  def fail!(error)
    @operation.fail!(error)
    OperationProgressBroadcaster.call(@operation)
  end
end
