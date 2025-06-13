require "json"
require "pathname"

namespace :data do
  # Helper method to determine the JSON file path
  # Priority: Task argument > Environment variable > Default path
  def get_json_file_path(task_arg_path, env_var_name = "GRAPH_MEM_JSON_FILE")
    default_path = File.join(Dir.home, ".codeium", "windsurf-next", "memories", "memory.json")
    file_path_str = task_arg_path || ENV[env_var_name] || default_path
    Pathname.new(file_path_str)
  end

  desc "Migrate data from JSON Lines file to the database (clears existing data).\r\n \
 Pass file_path as argument or set GRAPH_MEM_JSON_FILE env var.\r\n \
 Default: ~/.codeium/windsurf-next/memories/memory.json"
  task :migrate_json, [ :file_path ] => :environment do |t, args|
    json_file_path = get_json_file_path(args[:file_path])

    unless json_file_path.exist?
      puts "Error: JSON file not found at #{json_file_path}"
      exit 1
    end

    puts "Starting JSON data migration from #{json_file_path}"
    puts "*** THIS WILL CLEAR ALL EXISTING MemoryRelation, MemoryObservation, and MemoryEntity DATA ***"

    # Clear existing data
    puts "Clearing existing data..."
    MemoryRelation.delete_all
    MemoryObservation.delete_all
    MemoryEntity.delete_all
    puts "Existing data cleared."

    entity_lines = []
    relation_lines = []
    entity_name_to_id = {}
    line_num = 0

    # 1. Read and parse all lines
    puts "Reading and parsing JSON file..."
    begin
      json_file_path.each_line do |line|
        line_num += 1
        next if line.strip.empty?

        print "\rParsing line: #{line_num}"
        $stdout.flush

        begin
          parsed_line = JSON.parse(line)
          if parsed_line["type"] == "entity"
            entity_lines << parsed_line
          elsif parsed_line["type"] == "relation"
            relation_lines << parsed_line
          else
            puts "Warning: Skipping unknown type on line #{line_num}: #{parsed_line['type']}"
          end
        rescue JSON::ParserError => e
          puts "Error parsing JSON on line #{line_num}: #{e.message}"
          puts "Line content: #{line.strip}"
        end
      end
    rescue Errno::ENOENT
      puts "Error: Cannot open file #{json_file_path}"
      exit 1
    end
    puts "\nParsed #{entity_lines.count} entity lines and #{relation_lines.count} relation lines."

    # 2. Process Entities and Observations
    puts "Creating entities and observations..."
    created_entities = 0
    created_observations = 0
    processed_entities = 0
    total_entities = entity_lines.count

    entity_lines.each do |entity_data|
      processed_entities += 1
      next unless entity_data["name"] && entity_data["entityType"]

      print "\rCreating entities: #{processed_entities}/#{total_entities}"
      $stdout.flush

      entity = MemoryEntity.new(
        name: entity_data["name"],
        entity_type: entity_data["entityType"]
      )

      if entity.save
        entity_name_to_id[entity_data["name"]] = entity.id
        created_entities += 1

        (entity_data["observations"] || []).each do |obs_content|
          observation = MemoryObservation.new(
            memory_entity_id: entity.id,
            content: obs_content
          )
          if observation.save
            created_observations += 1
          else
            puts "\nWarning: Failed to save observation for new entity '#{entity_data['name']}'. Errors: #{observation.errors.full_messages.join(', ')}"
          end
        end
      else
        puts "\nWarning: Failed to save entity '#{entity_data['name']}'. Errors: #{entity.errors.full_messages.join(', ')}"
      end
    end
    puts "\nCreated #{created_entities} entities and #{created_observations} observations."

    # 3. Process Relations
    puts "Creating relations..."
    created_relations = 0
    skipped_relations_missing_data = 0
    processed_relations = 0
    total_relations = relation_lines.count

    relation_lines.each do |relation_data|
      processed_relations += 1
      from_name = relation_data["from"]
      to_name = relation_data["to"]
      relation_type = relation_data["relationType"]

      from_id = entity_name_to_id[from_name]
      to_id = entity_name_to_id[to_name]

      unless from_id && to_id && relation_type
        puts "\nWarning: Skipping relation due to missing data: From='#{from_name}' (ID: #{from_id || 'not found'}), To='#{to_name}' (ID: #{to_id || 'not found'}), Type='#{relation_type || 'missing'}'"
        skipped_relations_missing_data += 1
        next
      end

      print "\rCreating relations: #{processed_relations}/#{total_relations}"
      $stdout.flush

      relation = MemoryRelation.new(
        from_entity_id: from_id,
        to_entity_id: to_id,
        relation_type: relation_type
      )

      if relation.save
        created_relations += 1
      else
        puts "\nWarning: Failed to save relation From='#{from_name}' To='#{to_name}' Type='#{relation_type}'. Errors: #{relation.errors.full_messages.join(', ')}"
        # Consider if this should also increment a skipped counter
      end
    end
    puts "\nCreated #{created_relations} relations. Skipped #{skipped_relations_missing_data} relations due to missing entities/types."

    puts "JSON data migration finished."
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Append data from JSON Lines file to the database (adds missing, skips existing).\r\n \
 Pass file_path as argument or set GRAPH_MEM_JSON_FILE env var.\r\n \
 Default: ~/.codeium/windsurf-next/memories/memory.json"
  task :append_json, [ :file_path ] => :environment do |t, args|
    json_file_path = get_json_file_path(args[:file_path])

    unless json_file_path.exist?
      puts "Error: JSON file not found at #{json_file_path}"
      exit 1
    end

    puts "Starting JSON data append from #{json_file_path}"

    entity_lines = []
    relation_lines = []
    entity_name_to_id = {} # For entities processed in this run
    line_num = 0

    # 1. Read and parse all lines
    puts "Reading and parsing JSON file..."
    begin
      json_file_path.each_line do |line|
        line_num += 1
        next if line.strip.empty?

        print "\rParsing line: #{line_num}"
        $stdout.flush

        begin
          parsed_line = JSON.parse(line)
          if parsed_line["type"] == "entity"
            entity_lines << parsed_line
          elsif parsed_line["type"] == "relation"
            relation_lines << parsed_line
          else
            puts "Warning: Skipping unknown type on line #{line_num}: #{parsed_line['type']}"
          end
        rescue JSON::ParserError => e
          puts "Error parsing JSON on line #{line_num}: #{e.message}"
          puts "Line content: #{line.strip}"
        end
      end
    rescue Errno::ENOENT
      puts "Error: Cannot open file #{json_file_path}"
      exit 1
    end
    puts "\nParsed #{entity_lines.count} entity lines and #{relation_lines.count} relation lines."

    # 2. Process Entities and Observations
    puts "Processing entities and observations..."
    created_entities = 0
    found_entities = 0
    newly_created_observations = 0 # Total observations created (for new entities or appended to existing)
    processed_entities = 0
    total_entities = entity_lines.count

    entity_lines.each do |entity_data|
      processed_entities += 1
      next unless entity_data["name"] && entity_data["entityType"]

      print "\rProcessing entities: #{processed_entities}/#{total_entities}"
      $stdout.flush

      entity = MemoryEntity.find_or_initialize_by(name: entity_data["name"], entity_type: entity_data["entityType"])
      is_new_entity = entity.new_record?

      if is_new_entity
        if entity.save
          entity_name_to_id[entity_data["name"]] = entity.id
          created_entities += 1
          (entity_data["observations"] || []).each do |obs_content|
            observation = entity.memory_observations.build(content: obs_content)
            if observation.save
              newly_created_observations += 1
            else
              puts "\nWarning: Failed to save observation for new entity '#{entity_data['name']}'. Errors: #{observation.errors.full_messages.join(', ')}"
            end
          end
        else
          puts "\nWarning: Failed to save new entity '#{entity_data['name']}'. Errors: #{entity.errors.full_messages.join(', ')}"
        end
      else # Existing entity found
        entity_name_to_id[entity_data["name"]] = entity.id # Ensure it's in the map
        found_entities += 1
        (entity_data["observations"] || []).each do |obs_content|
          unless entity.memory_observations.exists?(content: obs_content)
            observation = entity.memory_observations.build(content: obs_content)
            if observation.save
              newly_created_observations += 1
            else
              puts "\nWarning: Failed to save appended observation for entity '#{entity_data['name']}'. Errors: #{observation.errors.full_messages.join(', ')}"
            end
          end
        end
      end
    end
    puts "\nProcessed #{total_entities} entity records from JSON."
    puts "Created #{created_entities} new entities."
    puts "Found #{found_entities} existing entities (observations may have been appended)."
    puts "Created/appended a total of #{newly_created_observations} observations."

    # 3. Process Relations
    puts "Processing relations..."
    created_relations = 0
    skipped_existing_relations = 0
    skipped_relations_missing_data = 0
    processed_relations = 0
    total_relations = relation_lines.count

    relation_lines.each do |relation_data|
      processed_relations += 1
      from_name = relation_data["from"]
      to_name = relation_data["to"]
      relation_type = relation_data["relationType"]

      # Find entity IDs, using the batch cache first, then falling back to DB query
      from_id = entity_name_to_id[from_name] ||= MemoryEntity.find_by(name: from_name)&.id
      to_id = entity_name_to_id[to_name] ||= MemoryEntity.find_by(name: to_name)&.id

      unless from_id && to_id && relation_type
        puts "\nWarning: Skipping relation due to missing entity data in DB or JSON batch: FromName='#{from_name}', ToName='#{to_name}', Type='#{relation_type}'"
        skipped_relations_missing_data += 1
        next
      end

      print "\rProcessing relations: #{processed_relations}/#{total_relations}"
      $stdout.flush

      if MemoryRelation.exists?(from_entity_id: from_id, to_entity_id: to_id, relation_type: relation_type)
        skipped_existing_relations += 1
      else
        relation = MemoryRelation.new(
          from_entity_id: from_id,
          to_entity_id: to_id,
          relation_type: relation_type
        )
        if relation.save
          created_relations += 1
        else
          puts "\nWarning: Failed to save new relation FromID='#{from_id}' ToID='#{to_id}' Type='#{relation_type}'. Errors: #{relation.errors.full_messages.join(', ')}"
        end
      end
    end
    puts "\nProcessed #{total_relations} relation records from JSON."
    puts "Created #{created_relations} new relations."
    puts "Skipped #{skipped_existing_relations} already existing relations."
    puts "Skipped #{skipped_relations_missing_data} relations due to missing entity data in this batch or missing type."

    puts "JSON data append finished."
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Merge one MemoryEntity into another. \n" \
       "Moves all relations and observations from the 'from' entity to the 'to' entity, then deletes the 'from' entity.\n" \
       "Args: from_id (integer), to_id (integer)"
  task :merge_entity, [ :from_id, :to_id ] => :environment do |_t, args|
    from_id_str = args[:from_id]
    to_id_str = args[:to_id]

    unless from_id_str && to_id_str
      puts "Error: Both from_id and to_id arguments are required."
      puts "Usage: rake db:merge_entity[from_id,to_id]"
      exit 1
    end

    begin
      from_id = Integer(from_id_str)
      to_id = Integer(to_id_str)
    rescue ArgumentError
      puts "Error: from_id and to_id must be valid integers."
      puts "Usage: rake db:merge_entity[from_id,to_id]"
      exit 1
    end

    if from_id == to_id
      puts "Error: from_id and to_id cannot be the same."
      exit 1
    end

    puts "Starting entity merge: from ID #{from_id} to ID #{to_id}"

    from_entity = MemoryEntity.find_by(id: from_id)
    to_entity = MemoryEntity.find_by(id: to_id)

    unless from_entity
      puts "Error: Source entity with ID #{from_id} not found."
      exit 1
    end

    unless to_entity
      puts "Error: Destination entity with ID #{to_id} not found."
      exit 1
    end

    puts "Found source entity: '#{from_entity.name}' (ID: #{from_entity.id}, Type: #{from_entity.entity_type})"
    puts "Found destination entity: '#{to_entity.name}' (ID: #{to_entity.id}, Type: #{to_entity.entity_type})"
    puts "---"

    ActiveRecord::Base.transaction do
      puts "Attempting to move observations..."
      observations_moved_count = from_entity.memory_observations.update_all(memory_entity_id: to_entity.id)
      puts "Moved #{observations_moved_count} observations from entity #{from_id} to entity #{to_id}."
      puts "---"

      puts "Attempting to update relations where entity #{from_id} was the source..."
      relations_as_source_updated_count = MemoryRelation.where(from_entity_id: from_id).update_all(from_entity_id: to_id)
      puts "Updated #{relations_as_source_updated_count} relations where entity #{from_id} was the source, to now originate from entity #{to_id}."
      puts "---"

      puts "Attempting to update relations where entity #{from_id} was the target..."
      relations_as_target_updated_count = MemoryRelation.where(to_entity_id: from_id).update_all(to_entity_id: to_id)
      puts "Updated #{relations_as_target_updated_count} relations where entity #{from_id} was the target, to now target entity #{to_id}."
      puts "---"

      # Note: If unique constraints exist (e.g., on [from_entity_id, to_entity_id, relation_type]),
      # the update_all operations might fail if a moved relation becomes a duplicate of an existing one.
      # The transaction will roll back in such cases.

      puts "Attempting to delete source entity #{from_entity.name} (ID: #{from_id})..."
      from_entity.destroy!
      puts "Source entity #{from_id} ('#{from_entity.name}') deleted successfully."
      puts "---"

      puts "Entity merge from ID #{from_id} to ID #{to_id} completed successfully."
    rescue ActiveRecord::RecordInvalid => e
      puts "Error during merge (RecordInvalid): #{e.message}. Transaction rolled back."
      puts "Validation errors: #{e.record.errors.full_messages.join(', ')}" if e.record
      exit 1
    rescue ActiveRecord::StatementInvalid => e
      puts "Error during merge (StatementInvalid, possibly unique constraint violation): #{e.message}. Transaction rolled back."
      exit 1
    rescue StandardError => e
      puts "An unexpected error occurred: #{e.message}. Transaction rolled back."
      puts "Backtrace:\n#{e.backtrace.join("\n")}"
      exit 1
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # --- HELPER METHODS for project_report ---

  def get_related_entities_by_type(project, relations, entity_type)
    related_entities = []
    relations.each do |relation|
      # Determine the 'other' entity in the relation
      other_entity = (relation.from_entity_id == project.id) ? relation.to_entity : relation.from_entity
      # Add if it matches the type and is not the project itself
      if other_entity.id != project.id && other_entity.entity_type == entity_type
        related_entities << other_entity
      end
    end
    related_entities.uniq
  end
  #-- -------------------------------------------------------------------------
  #++

  def generate_all_projects_diagram(projects, all_relations)
    project_map = projects.index_by(&:id) # For quick lookup

    mermaid = [ "```mermaid", "mindmap" ] # Start of the mindmap definition
    mermaid << "  root((Projects Interconnectivity))"

    projects.each do |p|
      # Sanitize project name for node label - mindmap nodes are defined by text and indentation only
      safe_project_name = p.name.gsub(/[():"'\[\]]/, "").strip
      # Append project ID to the label for clarity
      mermaid << "    #{safe_project_name}<br/>ID #{p.id}" # Level 1: Project node

      # Find outgoing relations from this project to other projects
      outgoing_relations = all_relations.select do |r|
        r.to_entity_id == p.id && project_map.key?(r.from_entity_id) && r.from_entity_id != p.id
      end

      outgoing_relations.each do |r|
        to_project = project_map[r.from_entity_id]
        if to_project # Should always be true due to project_map.key? check
          # Mindmap breaks syntax with special characters:
          safe_to_project_name = to_project.name.gsub(/[():"'\[\]]/, "").strip

          # Level 2: Related project and relation type, also including target project ID
          mermaid << "      ← #{safe_to_project_name}<br/>ID #{to_project.id}"
        end
      end
    end
    mermaid << "```"
    mermaid.join("\n")
  end
  #-- -------------------------------------------------------------------------
  #++

  def generate_project_overview_diagram(project, relations)
    entity_counts = Hash.new(0)
    relations.each do |relation|
      other_entity = (relation.from_entity_id == project.id) ? relation.to_entity : relation.from_entity
      entity_counts[other_entity.entity_type] += 1 if other_entity.id != project.id
    end

    # Sanitize project name for Class diagram
    safe_project_name = project.name.gsub(/[^a-zA-Z0-9_]/, "")

    mermaid = [ "```mermaid" ]
    mermaid << "classDiagram"
    mermaid << "  direction LR"

    # Define the project class with attributes
    mermaid << "  class #{safe_project_name}:::project {"
    mermaid << "    id : #{project.id}"
    mermaid << "    observations : #{project.memory_observations.count}"
    mermaid << "  }"

    entity_counts.each do |type, count|
      # Sanitize type for Class diagram class name
      safe_type_name = type.gsub(/[^a-zA-Z0-9_]/, "")

      # Define the entity type class with count attribute
      mermaid << "  class #{safe_type_name}:::entityType {"
      mermaid << "    total : #{count}"
      mermaid << "  }"

      # Define relationship with cardinality
      mermaid << "  #{safe_project_name} \"1\" --o \"#{count}\" #{safe_type_name} : has"
    end

    # Add styling
    mermaid << ""
    mermaid << "  classDef project fill:#f96,stroke:#333,stroke-width:2px,color:#000"
    mermaid << "  classDef entityType fill:#bbf,stroke:#33f,stroke-width:1px,color:#000"
    mermaid << "```"
    mermaid.join("\n")
  end
  #-- -------------------------------------------------------------------------
  #++

  def generate_project_issues_diagram(project, issues)
    # Sanitize project name for Class diagram
    safe_project_name = project.name.gsub(/[^a-zA-Z0-9_]/, "")

    mermaid = [ "```mermaid" ]
    mermaid << "classDiagram"
    mermaid << "  direction LR"

    # Define the project class
    mermaid << "  class #{safe_project_name}:::project {"
    mermaid << "    id : #{project.id}"
    mermaid << "    name : \"#{project.name.truncate(20)}\""
    mermaid << "  }"

    if issues.any?
      # Define the Issue class
      mermaid << "  class Issue:::issue {"
      mermaid << "    total : #{issues.count}"
      mermaid << "  }"

      # Define relationship with cardinality
      mermaid << "  #{safe_project_name} \"1\" --o \"#{issues.count}\" Issue : has"

      # Add individual issue details as comments
      mermaid << ""
      mermaid << "  %% Individual Issues:"
      issues.each do |issue|
        # Sanitize issue name for comment
        safe_issue_name = issue.name.gsub(/[%\r\n]/, " ").truncate(50)
        mermaid << "  %% - ID #{issue.id}: #{safe_issue_name}"
      end
    end

    # Add styling
    mermaid << ""
    mermaid << "  classDef project fill:#f96,stroke:#333,stroke-width:2px,color:#000"
    mermaid << "  classDef issue fill:#fbb,stroke:#f33,stroke-width:1px,color:#000"
    mermaid << "```"
    mermaid.join("\n")
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Generates a consolidated Markdown report with Mermaid diagrams for all projects.\n" \
       "Args: output_dir (optional, defaults to 'docs')"
  task :project_report, [ :output_dir ] => :environment do |t, args|
    puts "Generating project overview report..."

    # --- CONFIGURATION ---
    output_directory = args[:output_dir] || "docs"
    output_path = Rails.root.join(output_directory)
    FileUtils.mkdir_p(output_path)

    output_file = output_path.join("project_overview_report.md")
    max_detailed_issues = 10
    max_detailed_observations = 5

    # --- DATA GATHERING ---
    projects = MemoryEntity.where(entity_type: "Project").includes(:memory_observations)
    all_relations = MemoryRelation.includes(:from_entity, :to_entity)

    if projects.empty?
      puts "No 'Project' entities found."
      next
    end

    # --- REPORT ASSEMBLY ---
    report_content = []
    report_content << "# Project Knowledge Graph Overview"
    report_content << "Generated on: #{Time.now.utc.iso8601}"
    report_content << "\n---\n"

    # 1. Overall Project-to-Project Graph
    puts "Generating overall project-to-project graph..."
    report_content << "## All Projects Interconnectivity"
    report_content << generate_all_projects_diagram(projects, all_relations)

    report_content << "\n### Project IDs"
    projects.each do |project|
      report_content << "- #{project.id}: `#{project.name.truncate(150)}`"
    end
    report_content << "\n---\n"

    # 2. Individual Project Sections
    puts "Generating individual project sections..."
    projects.each do |project|
      puts "  - Processing: #{project.name}"
      project_relations = all_relations.filter do |r|
        r.from_entity_id == project.id || r.to_entity_id == project.id
      end

      report_content << "## Project: #{project.name}"
      report_content << "*ID: #{project.id}*"

      # A. Bird's Eye View Diagram
      report_content << "### Relationships Overview"
      report_content << generate_project_overview_diagram(project, project_relations)

      # B. Unresolved Issues Diagram
      issues = get_related_entities_by_type(project, project_relations, "Issue")
      if issues.any?
        report_content << "### Associated Issues"
        report_content << generate_project_issues_diagram(project, issues.take(max_detailed_issues))
      end

      # C. Important Observations List
      observations = project.memory_observations.order(created_at: :desc).limit(max_detailed_observations)
      if observations.any?
        report_content << "### Recent Observations"
        report_content << observations.map { |obs| "- `#{obs.created_at.to_date}`: #{obs.content.truncate(150)}" }.join("\n")
      end

      report_content << "\n---\n"
    end

    # --- FILE WRITING ---
    File.write(output_file, report_content.join("\n\n"))
    puts "\nReport generation complete."
    puts "Output file: #{output_file}"
  end
  #-- -------------------------------------------------------------------------
  #++
end
