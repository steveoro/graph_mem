# frozen_string_literal: true

module Api
  module V1
    class ContextController < ApplicationController
      skip_forgery_protection

      # GET /api/v1/context
      def show
        project_id = GraphMemContext.current_project_id

        unless project_id
          return render json: { status: "no_context", message: "No project context is currently set." }
        end

        entity = MemoryEntity.find_by(id: project_id)
        unless entity
          GraphMemContext.clear!
          return render json: { status: "context_cleared", message: "Previously set project (ID #{project_id}) no longer exists. Context cleared." }
        end

        render json: {
          status: "context_active",
          project_id: entity.id,
          project_name: entity.name,
          project_type: entity.entity_type,
          description: entity.description
        }
      end

      # POST /api/v1/context
      def create
        project_id = params[:project_id]&.to_i
        unless project_id
          return render json: { error: "project_id is required" }, status: :unprocessable_content
        end

        entity = MemoryEntity.find_by(id: project_id)
        unless entity
          return render json: { error: "Entity with ID #{project_id} not found" }, status: :not_found
        end

        GraphMemContext.current_project_id = project_id

        render json: {
          status: "context_set",
          project_id: entity.id,
          project_name: entity.name,
          project_type: entity.entity_type
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
