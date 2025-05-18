require "json"
require "pathname"

namespace :db do
  desc "Migrate data from JSON Lines file to the database (clears existing data)"
  task migrate_json: :environment do
    json_file_path = Pathname.new("/home/steve/.codeium/windsurf-next/memories/memory.json")
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

        # Progress output for parsing
        if line_num % 100 == 0
          print "\rParsing line: #{line_num}"
          $stdout.flush
        end

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
          # Optionally exit or just skip the line
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

      # Progress output for entity creation
      if processed_entities % 100 == 0 || processed_entities == total_entities
        print "\rCreating entities: #{processed_entities}/#{total_entities}"
        $stdout.flush
      end

      entity = MemoryEntity.new(
        name: entity_data["name"],
        entity_type: entity_data["entityType"]
        # Add other fields if they exist and map directly
      )

      if entity.save
        entity_name_to_id[entity_data["name"]] = entity.id
        created_entities += 1

        # Create observations
        (entity_data["observations"] || []).each do |obs_content|
          observation = MemoryObservation.new(
            memory_entity_id: entity.id,
            content: obs_content
          )
          if observation.save
            created_observations += 1
          else
            puts "Warning: Failed to save observation for entity '#{entity_data['name']}'. Errors: #{observation.errors.full_messages.join(', ')}"
          end
        end
      else
        puts "Warning: Failed to save entity '#{entity_data['name']}'. Errors: #{entity.errors.full_messages.join(', ')}"
      end
    end
    puts "\nCreated #{created_entities} entities and #{created_observations} observations."

    # 3. Process Relations
    puts "Creating relations..."
    created_relations = 0
    skipped_relations = 0
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
        puts "Warning: Skipping relation due to missing data: From='#{from_name}' (ID: #{from_id || 'not found'}), To='#{to_name}' (ID: #{to_id || 'not found'}), Type='#{relation_type || 'missing'}'"
        skipped_relations += 1
        next
      end

      # Progress output for relation creation
      if processed_relations % 100 == 0 || processed_relations == total_relations
        print "\rCreating relations: #{processed_relations}/#{total_relations}"
        $stdout.flush
      end

      relation = MemoryRelation.new(
        from_entity_id: from_id,
        to_entity_id: to_id,
        relation_type: relation_type
      )

      if relation.save
        created_relations += 1
      else
        puts "Warning: Failed to save relation From='#{from_name}' To='#{to_name}' Type='#{relation_type}'. Errors: #{relation.errors.full_messages.join(', ')}"
        skipped_relations += 1
      end
    end
    puts "\nCreated #{created_relations} relations. Skipped #{skipped_relations} relations due to missing entities/types."

    puts "JSON data migration finished."
  end
end
