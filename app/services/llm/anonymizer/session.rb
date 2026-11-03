# frozen_string_literal: true

module Llm
  module Anonymizer
    # One anonymization session (agent-CLI PR2): one per summary or judge call, one per scan (every
    # part and split shares it). It masks a Prompt's data segments, never its trusted ones, and
    # restores an answer exactly. The mapping lives only in this object: never logged, persisted,
    # serialized or put in an exception message.
    #
    #   session = scope.session
    #   masked = session.mask(prompt)              # => Masked(text: "… ⟦PRJ_3f9a⟧ …", counts: { "PRJ" => 1 }, secrets: 0)
    #   session.unmask(answer, json: true).text   # => the answer with the originals back
    class Session
      TYPES = Tokens::TYPES.join("|")
      # Input that already looks like a token can't be told apart from one (Decision 7).
      TOKEN_LIKE = Regexp.new("[⟦⟧]|\\b(?:#{TYPES})_[0-9a-f]{4,8}\\b", timeout: Detectors::TIMEOUT)
      TOKEN_SPAN = Regexp.new("⟦[^⟦⟧\\n]{1,40}⟧", timeout: Detectors::TIMEOUT)
      TOKEN_SPLIT = Regexp.new("(⟦[^⟦⟧\\n]{1,40}⟧)", timeout: Detectors::TIMEOUT)
      # The forms a model may write a token in: ⟦T_h⟧, ⟦ T_h ⟧, [[T_h]], ⟦SECRET⟧, or a bare T_h.
      ANSWER_TOKEN = Regexp.new("⟦\\s*(#{TYPES})_([0-9a-f]{4,8})\\s*⟧|\\[\\[\\s*(#{TYPES})_([0-9a-f]{4,8})\\s*\\]\\]|" \
                                "(⟦\\s*SECRET\\s*⟧)|\\b(#{TYPES})_([0-9a-f]{4,8})\\b", timeout: Detectors::TIMEOUT)
      REDACTED = "[redacted]"

      # @!attribute text [String] the masked prompt
      # @!attribute counts [Hash{String => Integer}] tokens written, per type
      # @!attribute secrets [Integer] secrets redacted
      Masked = Data.define(:text, :counts, :secrets)
      # @!attribute text [String] the restored answer
      # @!attribute leftovers [Integer] masked terms the answer wrote out in plain text
      Unmasked = Data.define(:text, :leftovers)

      # @param scope [Llm::Scope] whose projects' members join the dictionary
      def initialize(scope)
        @scope = scope
        @tokens = Tokens.new
        @masked_keys = Set.new
      end

      # @param prompt [Llm::Prompt]
      # @return [Masked]
      # @raise [Refused] on a token-like input, a leftover, a regex timeout, a dictionary over
      #   its cap or a token clash
      def mask(prompt)
        segments = prompt.segments
        data = segments.select { |segment| segment.kind == :data }.map(&:text)
        raise Refused, :collision if data.any? { |text| TOKEN_LIKE.match?(text) }

        data.flat_map { |text| Detectors.owners(text) }.uniq.each { |owner| dictionary.add("USER", owner) }
        counts = Hash.new(0)
        secrets = 0
        text = segments.map do |segment|
          next segment.text if segment.kind == :trusted

          masked, redacted = mask_data(segment.text, counts)
          secrets += redacted
          masked
        end.join
        Masked.new(text: text, counts: counts.to_h, secrets: secrets)
      rescue Regexp::TimeoutError
        raise Refused, :timeout
      end

      # @param text [String] the model's answer
      # @param json [Boolean] insert each original JSON-escaped (the answer is JSON)
      # @return [Unmasked]
      # @raise [RoundTripFailed] `:invented` for a bracketed token this session never made,
      #   `:partial` when brackets are left after restoring
      def unmask(text, json: false)
        restored = text.to_s.gsub(ANSWER_TOKEN) { restore(Regexp.last_match, json) }
        raise RoundTripFailed, :partial if restored.match?(/[⟦⟧]/)

        Unmasked.new(text: restored, leftovers: leftovers(text.to_s))
      rescue Regexp::TimeoutError
        raise RoundTripFailed, :timeout
      end

      # @return [String] never the mapping
      def inspect = "#<#{self.class.name}>"

      private

      def dictionary
        @dictionary ||= Dictionary.build(@scope)
      end

      # Detectors first (a URL is one token), then the dictionary outside the tokens; then the
      # result is scanned again and any hit refuses the call.
      def mask_data(text, counts)
        detected, secrets = Detectors.mask(text, @tokens, counts)
        masked = plain_chunks(detected).map { |chunk, token| token ? chunk : replace_terms(chunk, counts) }.join
        raise Refused, :leftover if leftover?(masked)

        [ masked, secrets ]
      end

      def replace_terms(chunk, counts)
        out = +""
        cursor = 0
        # Byte offsets: a character index into non-ASCII text costs O(n) per slice.
        dictionary.matches(chunk).each do |start, stop, type, key|
          out << chunk.byteslice(cursor, start - cursor) << @tokens.for(type, chunk.byteslice(start, stop - start))
          counts[type] += 1
          @masked_keys << key
          cursor = stop
        end
        out << chunk.byteslice(cursor, chunk.bytesize - cursor)
      end

      # The text between tokens, scanned the way mask_data split it.
      def leftover?(masked)
        Detectors.hit?(masked) || plain_chunks(masked).any? { |chunk, token| !token && dictionary.matches(chunk).any? }
      end

      # @return [Array(String, Boolean)] the chunks, and whether each is a token
      def plain_chunks(text)
        text.split(TOKEN_SPLIT).map { |chunk| [ chunk, TOKEN_SPAN.match?(chunk) ] }
      end

      def restore(match, json)
        return REDACTED if match[5]

        type, suffix = match[1] ? match.values_at(1, 2) : match[3] ? match.values_at(3, 4) : match.values_at(6, 7)
        original = @tokens.original(type, suffix)
        if original.nil?
          raise RoundTripFailed, :invented unless match[6]

          return match[0]
        end
        # A URL can hold a redacted secret: it comes back as [redacted], never as a bracket.
        original = original.gsub(Tokens::SECRET, REDACTED)
        json ? JSON.generate(original)[1...-1] : original
      end

      # Masked terms the answer wrote out itself.
      def leftovers(text)
        plain_chunks(text).sum do |chunk, token|
          token ? 0 : dictionary.matches(chunk).count { |_, _, _, key| @masked_keys.include?(key) }
        end
      end
    end
  end
end
