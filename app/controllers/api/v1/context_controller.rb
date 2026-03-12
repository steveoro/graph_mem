# frozen_string_literal: true

module Api
  module V1
    class ContextController < BaseController
      # GET /api/v1/context
      def show
        current_id = GraphMemContext.current_project_id

        unless current_id
          return render json: { status: "no_context", message: "No project context is currently set." }
        end

        entity = MemoryEntity.find_by(id: current_id)
        unless entity
          GraphMemContext.clear!
          return render json: { status: "context_cleared", message: "Previously set context entity (ID #{current_id}) no longer exists. Context cleared." }
        end

        render json: {
          status: "context_active",
          entity_id: entity.id,
          entity_name: entity.name,
          entity_type: entity.entity_type,
          description: entity.description
        }
      end

      # POST /api/v1/context
      def create
        entity_id = params[:entity_id]&.to_i
        unless entity_id
          return render_error("entity_id is required")
        end

        entity = MemoryEntity.find_by(id: entity_id)
        unless entity
          return render_error("Entity with ID #{entity_id} not found", status: :not_found)
        end

        GraphMemContext.current_project_id = entity_id

        render json: {
          status: "context_set",
          entity_id: entity.id,
          entity_name: entity.name,
          entity_type: entity.entity_type
        }
      end

      # DELETE /api/v1/context
      def destroy
        was_set = GraphMemContext.current_project_id.present?
        GraphMemContext.clear!

        render json: {
          status: "context_cleared",
          was_active: was_set
        }
      end
    end
  end
end
