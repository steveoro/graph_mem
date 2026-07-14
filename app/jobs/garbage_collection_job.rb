# frozen_string_literal: true

class GarbageCollectionJob < ApplicationJob
  queue_as :default

  def perform
    unless AppSettings.garbage_collector_enabled?
      Rails.logger.info("[GC] Skipping garbage collection — garbage collector is disabled")
      return
    end

    GraphIntegrityService.call
  end
end
