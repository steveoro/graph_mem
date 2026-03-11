# frozen_string_literal: true

module Api
  module V1
    class BaseController < ApplicationController
      skip_forgery_protection

      rescue_from ActiveRecord::RecordNotFound do |e|
        render json: { error: e.message }, status: :not_found
      end

      rescue_from ActionController::ParameterMissing do |e|
        render json: { error: e.message }, status: :unprocessable_content
      end

      private

      def render_error(message, status: :unprocessable_content, details: nil)
        body = { error: message }
        body[:details] = details if details
        render json: body, status: status
      end

      def render_validation_errors(model)
        render_error("Validation failed", details: model.errors.as_json)
      end
    end
  end
end
