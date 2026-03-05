# frozen_string_literal: true

module Api
  module V1
    class StatusController < ApplicationController
      # GET /api/v1/status
      def index
        render json: {
          status: "ok",
          version: GraphMem::VERSION
        }
      end

      # GET /api/v1/time
      def time
        render json: { current_time: Time.current.iso8601 }
      end
    end
  end
end
