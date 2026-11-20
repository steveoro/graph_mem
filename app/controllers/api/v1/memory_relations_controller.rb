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

        # A part_of moves membership: the lock before the transaction, the validating create (one
        # parent, no cycle) and the child's sync in it, so a name collision rolls the edge back.
        part_of = canonical_type == "part_of"
        saved = with_membership_lock_if(part_of) do
          ActiveRecord::Base.transaction do
            next false unless @memory_relation.save

            ProjectMembership.sync!(@memory_relation.from_entity) if part_of
            true
          end
        end
        saved ? render(json: @memory_relation, status: :created) : render_validation_errors(@memory_relation)
      rescue ProjectMembership::Collision, ProjectMembership::LockTimeout => e
        render_membership_error(e)
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

        # A type change into or out of part_of moves membership (RelationMembershipWrite).
        RelationMembershipWrite.update!(@memory_relation, attributes)
        render json: @memory_relation
      rescue ActiveRecord::RecordInvalid => e
        render_validation_errors(e.record)
      rescue ProjectMembership::Collision, ProjectMembership::LockTimeout, RelationSemantics::ValidationError => e
        render_membership_error(e)
      end

      # DELETE /api/v1/memory_relations/:id
      # Deleting a part_of edge syncs the former child's membership in the same transaction, under
      # the lock (RelationMembershipWrite): a name collision in the scope it moves to, or a busy
      # lock, answers 422 with nothing deleted.
      def destroy
        RelationMembershipWrite.destroy!(@memory_relation, reason: params[:reason])
        head :no_content
      rescue ProjectMembership::Collision, ProjectMembership::LockTimeout => e
        render_membership_error(e)
      end

      private

      def set_relation
        @memory_relation = MemoryRelation.find(params[:id])
      end

      # A refusal from the membership rules, as a validation failure (422, the error this API documents).
      def render_membership_error(error)
        message = error.is_a?(ProjectMembership::LockTimeout) ? "#{error.message}; retry shortly" : error.message
        render_error("Validation failed", details: { base: [ message ] })
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
