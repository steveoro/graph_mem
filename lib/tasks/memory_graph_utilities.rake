namespace :tools do
  desc "List all entities with pagination (default: page 1, per_page 20)"
  task :list_entities, [ :page, :per_page ] => :environment do |t, args|
    page = (args[:page] || 1).to_i
    per_page = (args[:per_page] || 20).to_i

    total_entities = MemoryEntity.count
    entities = MemoryEntity.order(:id).limit(per_page).offset((page - 1) * per_page)

    puts "===== MEMORY GRAPH ENTITIES (Page #{page}/#{(total_entities.to_f / per_page).ceil}) ====="
    puts "Total entities: #{total_entities}"
    puts "Showing #{entities.size} entities (#{per_page} per page)"
    puts "=" * 80

    entities.each do |entity|
      puts "ID: #{entity.id.to_s.rjust(5)} | Name: #{entity.name.ljust(30)} | Type: #{entity.entity_type}"
    end

    puts "=" * 80
    puts "Usage: bin/rails tools:list_entities[page,per_page]"
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Get detailed information about an entity by ID"
  task :get_entity, [ :entity_id ] => :environment do |t, args|
    entity_id = args[:entity_id].to_i
    entity = MemoryEntity.find_by(id: entity_id)

    if entity.nil?
      puts "Entity with ID #{entity_id} not found."
      next
    end

    observations = entity.memory_observations.order(:created_at)
    outgoing_relations = MemoryRelation.where(from_entity_id: entity_id).includes(:to_entity)
    incoming_relations = MemoryRelation.where(to_entity_id: entity_id).includes(:from_entity)

    puts "===== ENTITY DETAILS ====="
    puts "ID: #{entity.id}"
    puts "Name: #{entity.name}"
    puts "Type: #{entity.entity_type}"
    puts "Created at: #{entity.created_at}"
    puts "Updated at: #{entity.updated_at}"
    puts ""

    puts "--- OBSERVATIONS (#{observations.size}) ---"
    observations.each do |obs|
      puts "* #{obs.created_at.strftime('%Y-%m-%d %H:%M')} [ID: #{obs.id}]: #{obs.content}"
    end
    puts ""

    puts "--- OUTGOING RELATIONS (#{outgoing_relations.size}) ---"
    outgoing_relations.each do |rel|
      puts "* [ID: #{rel.id}] #{entity.name} --[#{rel.relation_type}]--> #{rel.to_entity.name} (ID: #{rel.to_entity.id})"
    end
    puts ""

    puts "--- INCOMING RELATIONS (#{incoming_relations.size}) ---"
    incoming_relations.each do |rel|
      puts "* [ID: #{rel.id}] #{rel.from_entity.name} (ID: #{rel.from_entity.id}) --[#{rel.relation_type}]--> #{entity.name}"
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Search entities by name or type (case-insensitive)"
  task :search_entities, [ :query ] => :environment do |t, args|
    query = args[:query].to_s

    if query.blank?
      puts "Please provide a search query."
      next
    end

    entities = MemoryEntity.where("LOWER(name) LIKE LOWER(?) OR LOWER(entity_type) LIKE LOWER(?)",
                                  "%#{query}%", "%#{query}%")

    puts "===== SEARCH RESULTS FOR '#{query}' ====="
    puts "Found #{entities.size} matching entities"
    puts "=" * 80

    entities.each do |entity|
      puts "ID: #{entity.id.to_s.rjust(5)} | Name: #{entity.name.ljust(30)} | Type: #{entity.entity_type}"
    end

    puts "=" * 80
    puts "Usage: bin/rails tools:search_entities[query]"
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Create a new entity"
  task :create_entity, [ :name, :type, :observation ] => :environment do |t, args|
    name = args[:name]
    type = args[:type]
    observation = args[:observation]

    if name.blank? || type.blank?
      puts "Please provide both name and type for the entity."
      puts "Usage: bin/rails tools:create_entity[name,type,\"observation text\"]"
      next
    end

    begin
      ActiveRecord::Base.transaction do
        entity = MemoryEntity.create!(name: name, entity_type: type)

        if observation.present?
          entity.memory_observations.create!(content: observation)
        end

        puts "Entity created successfully!"
        puts "ID: #{entity.id}"
        puts "Name: #{entity.name}"
        puts "Type: #{entity.entity_type}"
      end
    rescue => e
      puts "Error creating entity: #{e.message}"
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Create a relation between two entities"
  task :create_relation, [ :from_id, :to_id, :relation_type ] => :environment do |t, args|
    from_id = args[:from_id].to_i
    to_id = args[:to_id].to_i
    relation_type = args[:relation_type].to_s

    if from_id == 0 || to_id == 0 || relation_type.blank?
      puts "Please provide from_id, to_id, and relation_type."
      puts "Usage: bin/rails tools:create_relation[from_id,to_id,relation_type]"
      next
    end

    from_entity = MemoryEntity.find_by(id: from_id)
    to_entity = MemoryEntity.find_by(id: to_id)

    if from_entity.nil?
      puts "Error: From entity (ID: #{from_id}) not found."
      next
    end

    if to_entity.nil?
      puts "Error: To entity (ID: #{to_id}) not found."
      next
    end

    begin
      relation = MemoryRelation.create!(
        from_entity_id: from_id,
        to_entity_id: to_id,
        relation_type: relation_type
      )

      puts "Relation created successfully!"
      puts "ID: #{relation.id}"
      puts "#{from_entity.name} --[#{relation.relation_type}]--> #{to_entity.name}"
    rescue => e
      puts "Error creating relation: #{e.message}"
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Add an observation to an entity"
  task :add_observation, [ :entity_id, :content ] => :environment do |t, args|
    entity_id = args[:entity_id].to_i
    content = args[:content].to_s

    if entity_id == 0 || content.blank?
      puts "Please provide entity_id and content."
      puts "Usage: bin/rails tools:add_observation[entity_id,\"observation content\"]"
      next
    end

    entity = MemoryEntity.find_by(id: entity_id)

    if entity.nil?
      puts "Error: Entity (ID: #{entity_id}) not found."
      next
    end

    begin
      observation = entity.memory_observations.create!(content: content)

      puts "Observation added successfully!"
      puts "ID: #{observation.id}"
      puts "Entity: #{entity.name} (ID: #{entity.id})"
      puts "Content: #{observation.content}"
    rescue => e
      puts "Error adding observation: #{e.message}"
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Find relations by type"
  task :find_relations, [ :relation_type ] => :environment do |t, args|
    relation_type = args[:relation_type]

    if relation_type.blank?
      puts "Finding all relations..."
      relations = MemoryRelation.all.includes(:from_entity, :to_entity)
    else
      puts "Finding relations with type '#{relation_type}'..."
      relations = MemoryRelation.where(relation_type: relation_type).includes(:from_entity, :to_entity)
    end

    puts "Found #{relations.size} relations"
    puts "=" * 80

    relations.each do |rel|
      puts "ID: #{rel.id.to_s.rjust(5)} | #{rel.from_entity.name.ljust(30)} --[#{rel.relation_type}]--> #{rel.to_entity.name.ljust(30)}"
    end

    puts "=" * 80
    puts "Usage: bin/rails tools:find_relations[relation_type]"
  end
  #-- -------------------------------------------------------------------------
  #++

  desc "Export memory graph to DOT format for visualization with Graphviz"
  task :export_to_dot, [ :filename ] => :environment do |t, args|
    filename = args[:filename] || "memory_graph.dot"

    entities = MemoryEntity.all
    relations = MemoryRelation.all.includes(:from_entity, :to_entity)

    # Ensure filename ends with .dot
    filename = "#{filename}.dot" unless filename.end_with?(".dot")
    filepath = Rails.root.join("tmp", filename)

    File.open(filepath, "w") do |f|
      f.puts "digraph MemoryGraph {"
      f.puts "  // Graph styling"
      f.puts "  graph [rankdir=LR, fontname=\"Helvetica\", splines=true];"
      f.puts "  node [shape=box, style=filled, fillcolor=lightblue, fontname=\"Helvetica\"];"
      f.puts "  edge [fontname=\"Helvetica\"];"
      f.puts

      # Output entities grouped by type
      entity_types = entities.map(&:entity_type).uniq
      entity_types.each do |entity_type|
        f.puts "  // #{entity_type} entities"
        f.puts "  subgraph cluster_#{entity_type.downcase.gsub(/\W+/, '_')} {"
        f.puts "    label = \"#{entity_type}\";"
        f.puts "    style = filled;"
        f.puts "    color = lightgrey;"

        entities.select { |e| e.entity_type == entity_type }.each do |entity|
          # Escape quotes in names
          escaped_name = entity.name.gsub('"', '\\"')
          f.puts "    entity_#{entity.id} [label=\"#{escaped_name}\\nID: #{entity.id}\"];"
        end

        f.puts "  }"
        f.puts
      end

      # Output relations
      f.puts "  // Relations"
      relations.each do |rel|
        f.puts "  entity_#{rel.from_entity_id} -> entity_#{rel.to_entity_id} [label=\"#{rel.relation_type}\"];"
      end

      f.puts "}"
    end

    puts "Memory graph exported to #{filepath}"
    puts "You can visualize it using Graphviz:"
    puts "  dot -Tpng #{filepath} -o memory_graph.png"
    puts "  dot -Tsvg #{filepath} -o memory_graph.svg"
  end
  #-- -------------------------------------------------------------------------
  #++
end
