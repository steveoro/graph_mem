# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Generates vector embeddings via Ollama (or OpenAI-compatible) API.
# Configuration priority: AppSettings → ENV → defaults (see EmbeddingConfig).
class EmbeddingService
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  class EmbeddingError < StandardError; end

  class << self
    def instance
      @instance ||= new
    end

    delegate :embed, :embed_entity, :embed_observation,
             :embed_entity_binary, :embed_observation_binary,
             :backfill_all, :regenerate_all, :check_connection, to: :instance

    def config_snapshot
      EmbeddingConfig.resolved_config
    end

    def reset_instance!
      remove_instance_variable(:@instance) if defined?(@instance)
    end

    # Runtime check: does the DB have VECTOR columns?
    # Cached per-process to avoid repeated schema queries.
    def vector_enabled?
      return @vector_enabled if defined?(@vector_enabled)

      @vector_enabled = ActiveRecord::Base.connection
                          .column_exists?(:memory_entities, :embedding)
    rescue StandardError
      @vector_enabled = false
    end

    def reset_vector_cache!
      remove_instance_variable(:@vector_enabled) if defined?(@vector_enabled)
    end
  end

  def initialize(config: nil)
    config ||= EmbeddingConfig.resolved_config
    @base_url = config[:url].to_s.chomp("/")
    @model = config[:model].to_s
    @provider = config[:provider].to_s
    @dims = config[:dims].to_i
    @logger = Rails.logger
    @mutex = Mutex.new
  end

  # Generate an embedding vector for arbitrary text.
  # Returns an Array of floats, or nil on failure.
  def embed(text)
    return nil if text.blank?

    embed_with_retries(text, raise_on_failure: false)
  end

  # Generate an embedding vector and raise the final error on failure.
  def embed!(text)
    raise EmbeddingError, "Text is blank" if text.blank?

    embed_with_retries(text, raise_on_failure: true)
  end

  def last_error
    @last_error
  end

  # Build composite text and embed a MemoryEntity.
  # Updates the entity's embedding column in-place (no callbacks triggered).
  # No-op when vector columns are absent (MariaDB < 11.7).
  def embed_entity(entity)
    return unless self.class.vector_enabled?

    text = compose_entity_text(entity)
    vector = embed(text)
    return unless vector

    store_vector(entity, vector)
  end

  # Embed a MemoryObservation's content.
  # No-op when vector columns are absent.
  def embed_observation(observation)
    return unless self.class.vector_enabled?

    vector = embed(observation.content)
    return unless vector

    store_vector(observation, vector)
  end

  # Return packed binary embedding for a MemoryEntity.
  def embed_entity_binary(entity)
    return nil unless self.class.vector_enabled?

    text = compose_entity_text(entity)
    vector = embed(text)
    return nil unless vector

    vector.pack("e*")
  end

  # Return packed binary embedding for a MemoryObservation.
  def embed_observation_binary(observation)
    return nil unless self.class.vector_enabled?

    vector = embed(observation.content)
    return nil unless vector

    vector.pack("e*")
  end

  # Smoke-test the embedding endpoint (same path as rake embeddings:check).
  # Returns { ok:, dims:, latency_ms:, error: } — never raises.
  def check_connection
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    vector = embed!("connection test")
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

    if vector.nil?
      return { ok: false, dims: nil, latency_ms: latency_ms, error: "Embedding request returned nil" }
    end

    if vector.length != @dims
      return {
        ok: false,
        dims: vector.length,
        latency_ms: latency_ms,
        error: "Dimension mismatch: expected #{@dims}, got #{vector.length}"
      }
    end

    { ok: true, dims: vector.length, latency_ms: latency_ms, error: nil }
  rescue StandardError => e
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1) if start
    { ok: false, dims: nil, latency_ms: latency_ms, error: "#{e.class}: #{e.message}" }
  end

  # Force-recompute embeddings for every entity and observation,
  # overwriting existing vectors without nullifying the column first
  # (VECTOR columns on MariaDB 11.8+ cannot be set to NULL).
  def regenerate_all(batch_size: 100)
    unless self.class.vector_enabled?
      @logger.warn "EmbeddingService: vector columns not present, skipping regenerate"
      return { entities: 0, observations: 0 }
    end

    total_entities = 0
    total_observations = 0

    MemoryEntity.find_each(batch_size: batch_size) do |entity|
      embed_entity(entity)
      total_entities += 1
    end

    MemoryObservation.find_each(batch_size: batch_size) do |obs|
      embed_observation(obs)
      total_observations += 1
    end

    @logger.info "EmbeddingService: regenerated #{total_entities} entities, #{total_observations} observations"
    { entities: total_entities, observations: total_observations }
  end

  # Backfill embeddings for all entities and observations missing them.
  def backfill_all(batch_size: 100)
    unless self.class.vector_enabled?
      @logger.warn "EmbeddingService: vector columns not present, skipping backfill"
      return { entities: 0, observations: 0 }
    end

    total_entities = 0
    total_observations = 0

    MemoryEntity.where(embedding: nil).find_each(batch_size: batch_size) do |entity|
      embed_entity(entity)
      total_entities += 1
    end

    MemoryObservation.where(embedding: nil).find_each(batch_size: batch_size) do |obs|
      embed_observation(obs)
      total_observations += 1
    end

    @logger.info "EmbeddingService: backfilled #{total_entities} entities, #{total_observations} observations"
    { entities: total_entities, observations: total_observations }
  end

  private

  def embed_with_retries(text, raise_on_failure:)
    @last_error = nil
    retries = 0
    begin
      body = request_embedding(text)
      vector = extract_vector(body)
      validate_dimensions!(vector)
      vector
    rescue StandardError => e
      retries += 1
      if retries <= MAX_RETRIES
        delay = RETRY_BASE_DELAY * (2**(retries - 1))
        @logger.warn "EmbeddingService: retry #{retries}/#{MAX_RETRIES} after #{delay}s — #{e.message}"
        sleep(delay)
        retry
      end
      @logger.error "EmbeddingService: failed after #{MAX_RETRIES} retries — #{e.message}"
      @last_error = e
      raise if raise_on_failure

      nil
    end
  end

  def compose_entity_text(entity)
    parts = []
    parts << "#{entity.entity_type}: #{entity.name}" if entity.name.present?
    parts << "Aliases: #{entity.aliases}" if entity.aliases.present?
    parts << entity.description if entity.description.present?
    parts.join(". ")
  end

  def request_embedding(text)
    uri = URI("#{@base_url}/api/embed")
    payload = { model: @model, input: text }

    if @provider == "openai_compatible"
      uri = URI("#{@base_url}/embeddings")
      payload = { model: @model, input: text }
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = payload.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise EmbeddingError, "HTTP #{response.code}: #{response.body.to_s[0..200]}"
    end

    JSON.parse(response.body)
  end

  def extract_vector(body)
    if @provider == "openai_compatible"
      body.dig("data", 0, "embedding")
    else
      body.dig("embeddings", 0) || body["embedding"]
    end || raise(EmbeddingError, "No embedding found in response")
  end

  def validate_dimensions!(vector)
    return if vector.length == @dims

    raise EmbeddingError,
          "Dimension mismatch: expected #{@dims}, got #{vector.length}"
  end

  def store_vector(record, vector)
    text = "[#{vector.join(',')}]"
    table = record.class.table_name
    quoted = ActiveRecord::Base.connection.quote(text)
    ActiveRecord::Base.connection.execute(
      "UPDATE #{table} SET embedding = VEC_FromText(#{quoted}) WHERE id = #{record.id}"
    )
  end
end
