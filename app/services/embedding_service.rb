# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Generates vector embeddings via Ollama (or OpenAI-compatible) API.
# Configuration via environment variables:
#   OLLAMA_URL        - Base URL of the embedding server (default: http://localhost:11434)
#   EMBEDDING_MODEL   - Model name (default: nomic-embed-text)
#   EMBEDDING_PROVIDER- "ollama" or "openai_compatible" (default: ollama)
#   EMBEDDING_DIMS    - Expected dimension count (default: 768)
class EmbeddingService
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  class EmbeddingError < StandardError; end

  class << self
    def instance
      @instance ||= new
    end

    delegate :embed, :embed_entity, :embed_observation, :backfill_all, to: :instance

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

  def initialize(
    url: ENV.fetch("OLLAMA_URL", "http://localhost:11434"),
    model: ENV.fetch("EMBEDDING_MODEL", "nomic-embed-text"),
    provider: ENV.fetch("EMBEDDING_PROVIDER", "ollama"),
    dims: ENV.fetch("EMBEDDING_DIMS", "768").to_i
  )
    @base_url = url.chomp("/")
    @model = model
    @provider = provider.to_s
    @dims = dims
    @logger = Rails.logger
    @mutex = Mutex.new
  end

  # Generate an embedding vector for arbitrary text.
  # Returns an Array of floats, or nil on failure.
  def embed(text)
    return nil if text.blank?

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
      nil
    end
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
