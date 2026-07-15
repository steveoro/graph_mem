# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Generates text summaries via Ollama (or OpenAI-compatible) API.
# Configuration priority: AppSettings → ENV → defaults (see SummarizationConfig).
class SummaryGenerationClient
  MAX_OUTPUT_LENGTH = 8_192

  class GenerationError < StandardError; end

  class << self
    def instance
      @instance ||= new
    end

    delegate :generate, :check_connection, to: :instance

    def config_snapshot
      SummarizationConfig.resolved_config
    end

    def reset_instance!
      remove_instance_variable(:@instance) if defined?(@instance)
    end
  end

  def initialize(config: nil)
    config ||= SummarizationConfig.resolved_config
    @base_url = config[:url].to_s.chomp("/")
    @model = config[:model].to_s
    @provider = config[:provider].to_s
    @timeout = config[:timeout].to_i
    @max_tokens = config[:max_tokens].to_i
    @logger = Rails.logger
  end

  # Generate summary text from a prompt.
  # Returns { ok:, text:, error: } — never raises.
  def generate(prompt, style: "concise")
    return { ok: false, text: nil, error: "prompt is blank" } if prompt.blank?

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    text = request_generation(prompt, style: style)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

    if text.blank?
      return { ok: false, text: nil, error: "empty response", latency_ms: latency_ms }
    end

    { ok: true, text: truncate_output(text), error: nil, latency_ms: latency_ms }
  rescue StandardError => e
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1) if start
    @logger.warn "SummaryGenerationClient: generation failed — #{e.class}"
    { ok: false, text: nil, error: "provider_unavailable", latency_ms: latency_ms }
  end

  # Smoke-test the generation endpoint. Returns { ok:, error:, latency_ms: }.
  def check_connection
    result = generate("Reply with the single word: ok.", style: "concise")
  rescue StandardError => e
    { ok: false, error: "#{e.class}: #{e.message}", latency_ms: nil }
  else
    {
      ok: result[:ok],
      error: result[:error],
      latency_ms: result[:latency_ms]
    }
  end

  private

  def request_generation(prompt, style:)
    case @provider
    when "openai_compatible"
      request_openai_compatible(prompt, style: style)
    else
      request_ollama(prompt, style: style)
    end
  end

  def request_ollama(prompt, style:)
    uri = URI("#{@base_url}/api/generate")
    payload = {
      model: @model,
      prompt: prompt,
      stream: false,
      options: {
        temperature: style == "concise" ? 0.1 : 0.3,
        num_predict: @max_tokens
      }
    }

    body = perform_request(uri, payload)
    body["response"].to_s.strip.presence
  end

  def request_openai_compatible(prompt, style:)
    uri = URI("#{@base_url}/chat/completions")
    payload = {
      model: @model,
      messages: [
        { role: "system", content: system_instruction(style) },
        { role: "user", content: prompt }
      ],
      temperature: style == "concise" ? 0.1 : 0.3,
      max_tokens: @max_tokens
    }

    body = perform_request(uri, payload)
    body.dig("choices", 0, "message", "content").to_s.strip.presence
  end

  def perform_request(uri, payload)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = [ @timeout, 5 ].min
    http.read_timeout = @timeout

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = payload.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise GenerationError, "HTTP #{response.code}"
    end

    JSON.parse(response.body)
  end

  def system_instruction(style)
    if style == "concise"
      "Summarize only the supplied observations. Do not invent facts. Preserve uncertainty and conflicting statements."
    else
      "Synthesize the supplied observations into a clear summary. Do not invent facts. Note uncertainty and conflicts."
    end
  end

  def truncate_output(text)
    text.to_s[0, MAX_OUTPUT_LENGTH]
  end
end
