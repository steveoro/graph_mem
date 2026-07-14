# frozen_string_literal: true

module Api
  module V1
    class MemoryRelationsController < BaseController
      before_action :set_relation, only: [ :destroy, :show, :update ]

      # GET /api/v1/memory_relations
      def index
        @memory_relations = MemoryRelation.all
        @memory_relations = @memory_relations.where(from_entity_id: params[:from_entity_id]) if params[:from_entity_id].present?
        @memory_relations = @memory_relations.where(to_entity_id: params[:to_entity_id]) if params[:to_entity_id].present?
        if params[:relation_type].present?
          @memory_relations = @memory_relations.where(
            relation_type: MemoryRelation.canonical_relation_type(params[:relation_type])
          )
        end

        render json: @memory_relations
      end

      # POST /api/v1/memory_relations
      def create
        canonical_type = MemoryRelation.canonical_relation_type(relation_params[:relation_type])
        from_entity = MemoryEntity.find_by(id: relation_params[:from_entity_id])
        to_entity = MemoryEntity.find_by(id: relation_params[:to_entity_id])

        existing = MemoryRelation.find_by(
          from_entity_id: relation_params[:from_entity_id],
          to_entity_id: relation_params[:to_entity_id],
          relation_type: canonical_type
        )
        if existing
          return render json: existing, status: :ok
        end

        @memory_relation = MemoryRelation.new(
          from_entity: from_entity,
          to_entity: to_entity,
          relation_type: canonical_type,
          weight: relation_params[:weight],
          confidence: relation_params[:confidence],
          properties: relation_params[:properties] || {}
        )

        if @memory_relation.save
          render json: @memory_relation, status: :created
        else
          render_validation_errors(@memory_relation)
        end
      end

      # GET /api/v1/memory_relations/:id
      def show
        render json: @memory_relation
      end

      # PATCH/PUT /api/v1/memory_relations/:id
      def update
        if update_relation_params[:relation_type].present?
          canonical_type = MemoryRelation.canonical_relation_type(update_relation_params[:relation_type])
          existing = MemoryRelation.find_by(
            from_entity_id: @memory_relation.from_entity_id,
            to_entity_id: @memory_relation.to_entity_id,
            relation_type: canonical_type
          )
          if existing && existing.id != @memory_relation.id
            return render_error(
              "Relation already exists for this from/to pair and type",
              details: { existing_relation_id: existing.id }
            )
          end
        end

        attributes = update_relation_params.to_h
        attributes["relation_type"] = canonical_type if canonical_type

        if @memory_relation.update(attributes)
          render json: @memory_relation
        else
          render_validation_errors(@memory_relation)
        end
      end

      # DELETE /api/v1/memory_relations/:id
      def destroy
        begin
          Current.deletion_reason = params[:reason]
          @memory_relation.destroy!
        ensure
          Current.deletion_reason = nil
        end
        head :no_content
      end

      private

      def set_relation
        @memory_relation = MemoryRelation.find(params[:id])
      end

      def relation_params
        params.require(:memory_relation).permit(
          :from_entity_id,
          :to_entity_id,
          :relation_type,
          :weight,
          :confidence,
          properties: {}
        )
      end

      def update_relation_params
        params.require(:memory_relation).permit(
          :relation_type,
          :weight,
          :confidence,
          properties: {}
        )
      end
    end
  end
end
