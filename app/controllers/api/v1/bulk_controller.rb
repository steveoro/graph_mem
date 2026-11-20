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

        # Membership lock BEFORE the transaction when a relation is a part_of (the advisory-first rule
        # graph_write follows): each new part_of syncs its child's project_id inside the transaction.
        with_membership_lock_for(relations_data) do
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
              record = MemoryObservation.create!(
                memory_entity_id: obs[:entity_id],
                content: obs[:text_content],
                confidence: obs[:confidence],
                source: obs[:source],
                valid_from: obs[:valid_from],
                valid_until: obs[:valid_until],
                tags: obs[:tags] || []
              )
              created_observations << {
                observation_id: record.id,
                entity_id: record.memory_entity_id,
                confidence: record.confidence,
                source: record.source,
                valid_from: record.valid_from&.iso8601,
                valid_until: record.valid_until&.iso8601,
                tags: record.tags
              }
            rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
              errors << { type: "observation", index: idx, error: e.message }
              raise ActiveRecord::Rollback
            end
            raise ActiveRecord::Rollback if errors.any?

            relations_data.each_with_index do |rel, idx|
              created_relations << create_relation!(rel)
            rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ProjectMembership::Collision => e
              errors << { type: "relation", index: idx, error: e.message }
              raise ActiveRecord::Rollback
            end
            raise ActiveRecord::Rollback if errors.any?
          end
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
      rescue ProjectMembership::LockTimeout => e
        # Nothing was written (the lock comes first). 422 is the error this endpoint documents.
        render_error("Bulk operation rolled back", details: [ { type: "relation", error: "#{e.message}; retry shortly" } ])
      end

      private

      # @param relations_data [Array<Hash>] the request's relations
      # @yield the bulk transaction, under the membership lock when any relation is a part_of
      def with_membership_lock_for(relations_data, &block)
        part_of = relations_data.any? { |rel| MemoryRelation.canonical_relation_type(rel[:relation_type]) == "part_of" }
        part_of ? ProjectMembership.with_membership_lock(&block) : yield
      end

      # Creates one relation through the validating create path (single parent, no cycle) and, for a
      # part_of, syncs the child's project like graph_write does.
      # @param rel [Hash] from_entity_id, to_entity_id, relation_type, weight, confidence, properties
      # @return [Hash] the created relation, as the response lists it
      # @raise [ActiveRecord::RecordInvalid, ProjectMembership::Collision]
      def create_relation!(rel)
        record = MemoryRelation.create!(
          from_entity_id: rel[:from_entity_id],
          to_entity_id: rel[:to_entity_id],
          relation_type: MemoryRelation.canonical_relation_type(rel[:relation_type]),
          weight: rel[:weight],
          confidence: rel[:confidence],
          properties: rel[:properties] || {}
        )
        ProjectMembership.sync!(MemoryEntity.find(record.from_entity_id)) if record.relation_type == "part_of"
        {
          relation_id: record.id,
          from_entity_id: record.from_entity_id,
          to_entity_id: record.to_entity_id,
          relation_type: record.relation_type,
          weight: record.weight,
          confidence: record.confidence,
          properties: record.properties
        }
      end
    end
  end
end
