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
    end
  end
end
