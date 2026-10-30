# frozen_string_literal: true

module Api
  module V1
    class BaseController < ApplicationController
      include ApiAuthentication

      # Every write through /api/v1 is one change set (UI-4a); reads record nothing.
      around_action :record_change_set, unless: -> { request.get? || request.head? }

      rescue_from ActiveRecord::RecordNotFound do |e|
        render json: { error: e.message }, status: :not_found
      end

      rescue_from ActionController::ParameterMissing do |e|
        render json: { error: e.message }, status: :unprocessable_content
      end

      rescue_from ActiveRecord::RecordNotUnique do |e|
        render json: { error: "Relation already exists", details: e.message }, status: :unprocessable_content
      end

      private

      def record_change_set
        ChangeSet.record(kind: "api.write") { yield }
      end

      # CSRF is skipped for a valid Bearer token, and for any Bearer header on a
      # request with no session (authentication then refuses it with 401/403
      # rather than a CSRF 422). With a session, a junk Authorization header
      # still needs the CSRF token.
      def verify_authenticity_token
        return if valid_bearer_token? || (request.authorization.to_s.match?(/\ABearer\s/i) && session[:role].blank?)
        super
      end

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
