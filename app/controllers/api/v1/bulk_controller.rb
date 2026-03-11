# frozen_string_literal: true

module Api
  module V1
    class BulkController < BaseController
      MAX_OPERATIONS = 50

      # POST /api/v1/bulk
      def create
        entities_data = params[:entities] || []
        observations_data = params[:observations] || []
        relations_data = params[:relations] || []

        total_ops = entities_data.length + observations_data.length + relations_data.length
        if total_ops == 0
          return render_error("At least one operation is required")
        end
        if total_ops > MAX_OPERATIONS
          return render_error("Maximum #{MAX_OPERATIONS} operations per call (got #{total_ops})")
        end

        created_entities = []
        created_observations = []
        created_relations = []
        errors = []

        ActiveRecord::Base.transaction do
          entities_data.each_with_index do |ent, idx|
            entity = MemoryEntity.create!(name: ent[:name], entity_type: ent[:entity_type], aliases: ent[:aliases], description: ent[:description])
            (ent[:observations] || []).each { |text| MemoryObservation.create!(memory_entity: entity, content: text) }
            created_entities << { entity_id: entity.id, name: entity.name, entity_type: entity.entity_type }
          rescue ActiveRecord::RecordInvalid => e
            errors << { type: "entity", index: idx, error: e.record.errors.full_messages.join(", ") }
            raise ActiveRecord::Rollback
          end
          raise ActiveRecord::Rollback if errors.any?

          observations_data.each_with_index do |obs, idx|
            record = MemoryObservation.create!(memory_entity_id: obs[:entity_id], content: obs[:text_content])
            created_observations << { observation_id: record.id, entity_id: record.memory_entity_id }
          rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
            errors << { type: "observation", index: idx, error: e.message }
            raise ActiveRecord::Rollback
          end
          raise ActiveRecord::Rollback if errors.any?

          relations_data.each_with_index do |rel, idx|
            record = MemoryRelation.create!(from_entity_id: rel[:from_entity_id], to_entity_id: rel[:to_entity_id], relation_type: rel[:relation_type])
            created_relations << { relation_id: record.id, from_entity_id: record.from_entity_id, to_entity_id: record.to_entity_id, relation_type: record.relation_type }
          rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
            errors << { type: "relation", index: idx, error: e.message }
            raise ActiveRecord::Rollback
          end
          raise ActiveRecord::Rollback if errors.any?
        end

        if errors.any?
          return render_error("Bulk operation rolled back", details: errors)
        end

        render json: {
          created_entities: created_entities,
          created_observations: created_observations,
          created_relations: created_relations,
          summary: { entities_created: created_entities.length, observations_created: created_observations.length, relations_created: created_relations.length }
        }, status: :created
      end
    end
  end
end
