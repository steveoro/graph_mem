# frozen_string_literal: true

require "openssl"

module Llm
  module Anonymizer
    # The anonymizer won't let a prompt out (fail closed). The message names the kind only, never
    # any text: `:collision`, `:leftover`, `:timeout`, `:dictionary_cap`, `:token_clash`.
    class Refused < StandardError
      # @return [Symbol]
      attr_reader :kind

      # @param kind [Symbol]
      def initialize(kind)
        @kind = kind
        super("anonymizer refused (#{kind})")
      end
    end

    # An answer can't be restored exactly: `:invented` (a token not in the map) or `:partial`
    # (brackets left over). The message names the kind only.
    class RoundTripFailed < StandardError
      # @return [Symbol]
      attr_reader :kind

      # @param kind [Symbol]
      def initialize(kind)
        @kind = kind
        super("anonymization round trip failed (#{kind})")
      end
    end

    # One session's reversible tokens: `⟦TYPE_hhhh⟧`, hhhh the first 4 hex of
    # HMAC-SHA256(salt, "TYPE\0surface"), lengthened to 6, then 8, when another surface of the same
    # type already has it. One token per surface form, so restoring gives back the exact text.
    # The salt is random per session: stable within one call (or one scan), unlinkable across them.
    #
    #   tokens = Llm::Anonymizer::Tokens.new
    #   tokens.for("PRJ", "Gadget Project") # => "⟦PRJ_3f9a⟧"
    #   tokens.original("PRJ", "3f9a")      # => "Gadget Project"
    class Tokens
      TYPES = %w[PRJ ENT PER PATH HOST URL EMAIL IP USER].freeze
      # A redacted secret: never in the map, restored as "[redacted]".
      SECRET = "⟦SECRET⟧"
      SUFFIX_LENGTHS = [ 4, 6, 8 ].freeze

      def initialize
        @salt = SecureRandom.bytes(32)
        @by_surface = {}
        @by_token = {}
      end

      # @param type [String] one of TYPES
      # @param surface [String] the exact text masked
      # @return [String] its token, the same one every time in this session
      # @raise [Refused] `:token_clash` when even 8 hex digits clash
      def for(type, surface)
        @by_surface[[ type, surface ]] ||= begin
          digest = OpenSSL::HMAC.hexdigest("SHA256", @salt, "#{type}\0#{surface}")
          token = SUFFIX_LENGTHS.map { |length| "⟦#{type}_#{digest[0, length]}⟧" }.find { |candidate| !@by_token.key?(candidate) }
          raise Refused, :token_clash unless token

          @by_token[token] = surface
          token
        end
      end

      # @param type [String]
      # @param suffix [String] the hex part
      # @return [String, nil] the original surface, nil for a token this session never made
      def original(type, suffix)
        @by_token["⟦#{type}_#{suffix}⟧"]
      end

      # @return [String] never the map
      def inspect = "#<#{self.class.name}>"
    end
  end
end
