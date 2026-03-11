# frozen_string_literal: true

module Api
  module V1
    class MaintenanceController < BaseController
      # GET /api/v1/maintenance/suggest_merges
      def suggest_merges
        threshold = (params[:threshold] || 0.3).to_f
        limit = (params[:limit] || 20).to_i
        entity_type = params[:entity_type]

        scope = MemoryEntity.where.not(embedding: nil)
        scope = scope.where(entity_type: entity_type) if entity_type.present?

        entities = scope.to_a
        suggestions = []

        entities.each do |entity|
          break if suggestions.length >= limit

          next if entity.embedding.blank?

          candidates = MemoryEntity
            .where.not(id: entity.id)
            .where.not(embedding: nil)
            .where("id > ?", entity.id)
            .select("memory_entities.*, VEC_DISTANCE_COSINE(embedding, (SELECT embedding FROM memory_entities WHERE id = #{entity.id})) AS vec_distance")
            .having("vec_distance < ?", threshold)
            .order(Arel.sql("vec_distance ASC"))
            .limit(3)

          candidates.each do |candidate|
            suggestions << {
              entity_a: { entity_id: entity.id, name: entity.name, entity_type: entity.entity_type },
              entity_b: { entity_id: candidate.id, name: candidate.name, entity_type: candidate.entity_type },
              cosine_distance: candidate[:vec_distance].to_f.round(4),
              recommendation: candidate[:vec_distance].to_f < 0.15 ? "high_confidence_merge" : "review_manually"
            }
            break if suggestions.length >= limit
          end
        end

        render json: { suggestions: suggestions, total: suggestions.length, threshold_used: threshold }
      end

      # GET /api/v1/maintenance/stats
      def stats
        render json: {
          totals: {
            entities: MemoryEntity.count,
            observations: MemoryObservation.count,
            relations: MemoryRelation.count,
            audit_logs: AuditLog.count
          },
          entity_type_distribution: MemoryEntity.group(:entity_type).order("count_all DESC").count,
          orphan_count: MemoryEntity
            .left_joins(:memory_observations)
            .where(memory_observations: { id: nil })
            .where.not(id: MemoryRelation.select(:from_entity_id))
            .where.not(id: MemoryRelation.select(:to_entity_id))
            .count,
          stale_count: MemoryEntity.where("updated_at < ?", 6.months.ago).count,
          most_connected: most_connected_entities,
          recently_updated: MemoryEntity.order(updated_at: :desc).limit(10).pluck(:id, :name, :entity_type, :updated_at)
            .map { |id, name, type, at| { id: id, name: name, entity_type: type, updated_at: at.iso8601 } }
        }
      end

      private

      def most_connected_entities
        from_counts = MemoryRelation.group(:from_entity_id).count
        to_counts = MemoryRelation.group(:to_entity_id).count
        merged = from_counts.merge(to_counts) { |_k, a, b| a + b }

        merged.sort_by { |_id, cnt| -cnt }.first(10).filter_map do |entity_id, count|
          entity = MemoryEntity.find_by(id: entity_id)
          next unless entity
          { id: entity.id, name: entity.name, entity_type: entity.entity_type, relation_count: count }
        end
      end
    end
  end
end
