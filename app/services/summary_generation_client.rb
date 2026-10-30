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
    @num_ctx = (config[:num_ctx] || SummarizationConfig::DEFAULTS[:num_ctx]).to_i
    @logger = Rails.logger
  end

  # Generate summary text from a prompt.
  # Returns { ok:, text:, error: } — never raises.
  #
  # @param prompt [String]
  # @param style [String] "concise" or "detailed" (sets the temperature)
  # @param options [Hash] merged over the defaults:
  #   - `num_ctx:` (Integer, Ollama only) the context window;
  #   - `num_predict:` (Integer) the output cap instead of max_tokens (`max_tokens` on openai_compatible);
  #   - `format:` (String, Ollama only) "json" asks Ollama for JSON output;
  #   - `truncate:` (Boolean, Ollama only) false asks Ollama to refuse an over-long prompt instead of
  #     dropping its start;
  #   - `timeout:` (Integer seconds) the read timeout of this request only;
  #   - `max_output_length:` (Integer, or nil for no cut) the characters kept, MAX_OUTPUT_LENGTH by default
  # @return [Hash] `{ ok:, text:, error:, latency_ms:, prompt_tokens:, done_reason: }`; `prompt_tokens`
  #   (Ollama's prompt_eval_count) and `done_reason` ("stop", "length", …) are nil when the provider
  #   doesn't return them
  def generate(prompt, style: "concise", options: {})
    return { ok: false, text: nil, error: "prompt is blank" } if prompt.blank?

    options = options.to_h.symbolize_keys
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    answer = request_generation(prompt, style: style, options: options)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

    if answer[:text].blank?
      return { ok: false, text: nil, error: "empty response", latency_ms: latency_ms }
    end

    max_length = options.key?(:max_output_length) ? options[:max_output_length] : MAX_OUTPUT_LENGTH
    { ok: true, text: truncate_output(answer[:text], max_length), error: nil, latency_ms: latency_ms,
      prompt_tokens: answer[:prompt_tokens], done_reason: answer[:done_reason] }
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

  def request_generation(prompt, style:, options:)
    case @provider
    when "openai_compatible"
      request_openai_compatible(prompt, style: style, options: options)
    else
      request_ollama(prompt, style: style, options: options)
    end
  end

  # @return [Hash] `{ text:, prompt_tokens:, done_reason: }`
  def request_ollama(prompt, style:, options:)
    uri = URI("#{@base_url}/api/generate")
    payload = {
      model: @model,
      prompt: prompt,
      stream: false,
      options: {
        temperature: style == "concise" ? 0.1 : 0.3,
        num_predict: (options[:num_predict] || @max_tokens).to_i,
        num_ctx: (options[:num_ctx] || @num_ctx).to_i
      }
    }
    payload[:format] = options[:format].to_s if options[:format].present?
    payload[:truncate] = options[:truncate] == true unless options[:truncate].nil?

    body = perform_request(uri, payload, timeout: options[:timeout])
    { text: body["response"].to_s.strip.presence, prompt_tokens: body["prompt_eval_count"]&.to_i, done_reason: body["done_reason"]&.to_s }
  end

  # @return [Hash] `{ text:, prompt_tokens:, done_reason: }`
  def request_openai_compatible(prompt, style:, options:)
    uri = URI("#{@base_url}/chat/completions")
    payload = {
      model: @model,
      messages: [
        { role: "system", content: system_instruction(style) },
        { role: "user", content: prompt }
      ],
      temperature: style == "concise" ? 0.1 : 0.3,
      max_tokens: (options[:num_predict] || @max_tokens).to_i
    }

    body = perform_request(uri, payload, timeout: options[:timeout])
    { text: body.dig("choices", 0, "message", "content").to_s.strip.presence,
      prompt_tokens: body.dig("usage", "prompt_tokens")&.to_i, done_reason: body.dig("choices", 0, "finish_reason")&.to_s }
  end

  def perform_request(uri, payload, timeout: nil)
    timeout = (timeout || @timeout).to_i
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = [ timeout, 5 ].min
    http.read_timeout = timeout

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

  def truncate_output(text, max_length)
    max_length.nil? ? text.to_s : text.to_s[0, max_length.to_i]
  end
end
