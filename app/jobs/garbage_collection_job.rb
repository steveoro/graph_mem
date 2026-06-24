# frozen_string_literal: true

class GarbageCollectionJob < ApplicationJob
  queue_as :default

  STALE_MONTHS = 6

  def perform
    GarbageCollectionRunner.call
  end
end
