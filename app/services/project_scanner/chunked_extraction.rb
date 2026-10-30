# frozen_string_literal: true

class ProjectScanner
  # Sends a scan's parts to the model, one request each, and merges the answers (F-3).
  #
  # A part fails when the request fails, the answer was cut (`done_reason` "length"), the prompt
  # was cut (Ollama's `prompt_eval_count` at or above num_ctx − num_predict, or an HTTP 400/413
  # refusal of the prompt, which `truncate: false` asks for) or the answer isn't a JSON object with
  # an `architecture` array. A failed part is split in half once (between its
  # file blocks, or between the lines of its only block) and both halves are sent; a half that
  # fails is final. A provider error isn't retried, and after MAX_PROVIDER_ERRORS in a row the
  # remaining parts are skipped as failed.
  #
  #   outcome = ProjectScanner::ChunkedExtraction.new(chunks: plan.chunks, project_name: "Gadget Project",
  #                                                   num_ctx: 8192, num_predict: 2048, timeout: 120).call
  #   outcome.data         # => the merged { "project" => …, "architecture" => [...] }, or nil when every part failed
  #   outcome.parts_failed # => 0
  class ChunkedExtraction
    MAX_NAMES = 50
    MAX_PROVIDER_ERRORS = 2
    PROVIDER_ERROR = "provider_unavailable"
    PROMPT_REJECTED = "prompt rejected by the provider (too long for the window)"
    # The statuses Ollama refuses an over-long prompt with: split the part, it isn't an outage.
    PROMPT_REJECTED_STATUSES = [ 400, 413 ].freeze

    Unit = Data.define(:pieces, :splittable)
    Outcome = Data.define(:data, :parts_total, :parts_done, :parts_failed, :first_error)

    # @param chunks [Array<ChunkPlanner::Chunk>]
    # @param project_name [String] named in every part's header
    # @param num_ctx [Integer]
    # @param num_predict [Integer] the answer budget per part
    # @param timeout [Integer] seconds per request
    # @param on_part [#call, nil] called before each request with `(part, parts)`
    def initialize(chunks:, project_name:, num_ctx:, num_predict:, timeout:, on_part: nil)
      @queue = chunks.map { |chunk| Unit.new(pieces: chunk.pieces, splittable: true) }
      @project_name = project_name
      @num_ctx = num_ctx.to_i
      @num_predict = num_predict.to_i
      @timeout = timeout.to_i
      @on_part = on_part
      @merger = ExtractionMerger.new
    end

    # @return [Outcome]
    def call
      @total = @queue.size
      @done = 0
      @failed = 0
      @first_error = nil
      provider_errors = 0

      until @queue.empty?
        unit = @queue.shift
        if provider_errors >= MAX_PROVIDER_ERRORS
          fail_part(PROVIDER_ERROR)
          next
        end

        error = extract(unit, @done + @failed + 1)
        provider_errors = error == PROVIDER_ERROR ? provider_errors + 1 : 0
        next unless error

        halves = error == PROVIDER_ERROR || !unit.splittable ? nil : split(unit)
        if halves
          @queue.unshift(*halves)
          @total += 1
        else
          fail_part(error)
        end
      end

      Outcome.new(data: @done.positive? ? @merger.result : nil, parts_total: @total, parts_done: @done,
                  parts_failed: @failed, first_error: @first_error)
    end

    private

    # @return [String, nil] why the part failed
    def extract(unit, part)
      @on_part&.call(part, @total)
      prompt = ExtractionPrompt.text(unit.pieces.join("\n"), part: part, parts: @total, project_name: @project_name,
                                                             names: @merger.names(limit: MAX_NAMES))
      result = SummaryGenerationClient.generate(prompt, style: "concise", options: request_options)
      error = failure(result)
      return error if error

      @merger.add(ExtractionPrompt.parse_json(result[:text]))
      @done += 1
      nil
    end

    def request_options
      { num_ctx: @num_ctx, num_predict: @num_predict, format: "json", truncate: false, timeout: @timeout, max_output_length: nil }
    end

    def failure(result)
      return PROMPT_REJECTED if !result[:ok] && PROMPT_REJECTED_STATUSES.include?(result[:http_status])
      return result[:error].presence || PROVIDER_ERROR unless result[:ok]
      return "answer cut at num_predict #{@num_predict} (done_reason: length)" if result[:done_reason] == "length"

      window = @num_ctx - @num_predict
      return "prompt cut: #{result[:prompt_tokens]} prompt tokens for a #{window}-token window" if result[:prompt_tokens].to_i >= window

      "LLM response was not valid JSON" unless ExtractionMerger.usable?(ExtractionPrompt.parse_json(result[:text]))
    end

    def fail_part(error)
      @failed += 1
      @first_error ||= error
    end

    # @return [Array<Unit>, nil] two halves, or nil when the part can't be split
    def split(unit)
      pieces = unit.pieces.size > 1 ? unit.pieces : split_lines(unit.pieces.first)
      return nil if pieces.nil? || pieces.size < 2

      middle = pieces.size / 2
      [ pieces.first(middle), pieces.drop(middle) ].map { |half| Unit.new(pieces: half, splittable: false) }
    end

    # One "--- FILE: x\n…\n---\n" block as two blocks of half its lines, labelled "(half k of 2)".
    def split_lines(piece)
      header, *body = piece.to_s.lines
      body.pop if body.last&.chomp == "---"
      return nil if header.nil? || body.size < 2

      middle = body.size / 2
      [ body.first(middle), body.drop(middle) ].each_with_index.map do |lines, i|
        "#{header.chomp} (half #{i + 1} of 2)\n#{lines.join.chomp}\n---\n"
      end
    end
  end
end
