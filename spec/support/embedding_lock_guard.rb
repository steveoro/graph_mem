# frozen_string_literal: true

# Fails the example when an embedding call runs while this thread holds the membership lock
# (ProjectMembership.with_membership_lock): the lock is never held across a network call.
#
# It wraps EmbeddingService's public embedding calls (embed, embed!, embed_entity,
# embed_observation and the two binary forms), which the class-level API delegates to, so the
# real client and the `:with_test_embeddings` stub (spec/support/embedding_helper.rb stubs the
# private call below `embed`) both pass it. The check comes before `vector_enabled?`, so it also
# sees the inline embeddings of the specs that run with vectors off (most of them). No tag turns
# it off. A spec that stubs one of these methods itself replaces the check with its stub.
#
# The models' embedding callbacks rescue their own errors, so a raised error could pass unnoticed;
# every attempt is also recorded, and the example fails in an `after` hook.
module EmbeddingLockGuard
  # Raised in place of an embedding call made under the membership lock.
  class Violation < StandardError; end

  GUARDED_METHODS = %i[embed embed! embed_entity embed_observation embed_entity_binary embed_observation_binary].freeze
  FIX = "The membership lock is never held across a network call. A model's inline embedding is " \
        "deferred to the outermost lock's exit (EmbeddingService.defer_inline_embedding, called by the " \
        "embedding callbacks); a bulk path suppresses it (EmbeddingService.suppress_inline_embeddings) and " \
        "enqueues the embedding backfill after the commit; any other embedding call moves before or after the lock."
  # Frames inside these files are the embedding plumbing, not the caller to fix.
  PLUMBING = %w[app/services/embedding_service.rb app/services/embedding_service/ app/models/memory_entity.rb
                app/models/memory_observation.rb].freeze
  LISTED_FRAMES = 4

  @attempts = []
  @mutex = Mutex.new

  class << self
    # @param method [Symbol] the EmbeddingService method called
    # @param locations [Array<Thread::Backtrace::Location>] its callers, nearest first
    # @return [void]
    # @raise [Violation] when this thread holds the membership lock
    def check!(method, locations)
      return unless ProjectMembership.membership_lock_held?

      message = "EmbeddingService##{method} called under the membership lock from #{callers(locations)}"
      @mutex.synchronize { @attempts << message }
      raise Violation, "#{message}. #{FIX}"
    end

    # Returns and clears the attempts recorded so far.
    # @return [Array<String>]
    def drain!
      @mutex.synchronize { @attempts.slice!(0..) }
    end

    private

    # The nearest repo frames outside the plumbing, nearest first.
    def callers(locations)
      root = "#{Rails.root}/"
      frames = locations.filter_map do |location|
        path = location.absolute_path.to_s
        next unless path.start_with?(root) && path != __FILE__

        relative = path.delete_prefix(root)
        "#{relative}:#{location.lineno}" unless relative.start_with?("vendor/") || PLUMBING.any? { |plumbing| relative.start_with?(plumbing) }
      end
      frames.first(LISTED_FRAMES).join(" < ").presence || "(no repo frame)"
    end
  end

  # Prepended to EmbeddingService.
  module Calls
    GUARDED_METHODS.each do |name|
      define_method(name) do |*args, &block|
        EmbeddingLockGuard.check!(name, caller_locations(1))
        super(*args, &block)
      end
    end
  end
end

EmbeddingService.prepend(EmbeddingLockGuard::Calls)

RSpec.configure do |config|
  config.before { EmbeddingLockGuard.drain! }

  config.after do
    attempts = EmbeddingLockGuard.drain!
    next if attempts.empty?

    raise EmbeddingLockGuard::Violation, "#{attempts.uniq.join("\n")}\n#{EmbeddingLockGuard::FIX}"
  end
end
