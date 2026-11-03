# frozen_string_literal: true

module Llm
  module Anonymizer
    # Built-in patterns, run on a data segment before the dictionary, secrets first. Each regex has
    # a 1-second timeout; a timeout refuses the call (Session). Secrets become the untyped
    # ⟦SECRET⟧ (never restorable); URLs, e-mails, IPs, private hosts and absolute paths become
    # typed tokens, whole. The owner of a home-directory path is returned by `owners` so the
    # session masks that username everywhere.
    module Detectors
      TIMEOUT = 1.0
      PRIVATE_SUFFIXES = %w[local lan internal home corp intranet localdomain].freeze
      # Never next to a token: input can't contain ⟦ or ⟧ (Session refuses it), so this matters only
      # when a masked text is scanned again for leftovers. An underscore is a boundary (host_10.0.0.1).
      EDGE = "⟦⟧"

      def self.regex(source, options = 0) = Regexp.new(source, options, timeout: TIMEOUT)

      SECRETS = [
        regex("-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----", Regexp::MULTILINE),
        regex('\bsk-[A-Za-z0-9_-]{20,}'),
        regex('\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
        regex('\bxox[abpr]-[A-Za-z0-9-]{10,}'),
        regex('\bAKIA[0-9A-Z]{16}\b'),
        regex('\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}'),
        # The value after password / secret / token / api key / access or private key, env-style and
        # compound names too (DB_PASSWORD=, OPENAI_API_KEY=, aws_secret_access_key =), with = or :.
        regex("(?<![A-Za-z0-9])(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)(?:[_-][A-Za-z0-9]+)*" \
              '["\']?\s*[:=]\s*["\']?\K[^\s"\',;)⟦⟧]{4,}', Regexp::IGNORECASE)
      ].freeze
      # A long run (base64 and URL-safe base64 included) that looks random: see random?.
      ENTROPY = regex("(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{32,}(?![A-Za-z0-9+/=_-])")

      TYPED = [
        [ "URL", regex('(?<![\p{L}\p{N}])(?:https?|ftp|ssh|git|wss?)://[^\s<>"\'`)\]]*[^\s<>"\'`)\].,;:!?]', Regexp::IGNORECASE) ],
        [ "URL", regex('\b[\w.-]+@[\w.-]+:[\w./~-]+?\.git\b') ],
        [ "EMAIL", regex("(?<![#{EDGE}])\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}\\b(?![#{EDGE}])") ],
        [ "IP", regex("(?<![\\p{L}\\p{N}.#{EDGE}])(?:(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)(?![\\p{L}\\p{N}.#{EDGE}])") ],
        # IPv6 in either case, with a digit somewhere (so Ruby's Abc::Def is not one).
        [ "IP", regex("(?<![\\p{L}\\p{N}:#{EDGE}])(?=[0-9a-f:]*\\d)(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,6}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,5})?)" \
                      "(?![\\p{L}\\p{N}:#{EDGE}])", Regexp::IGNORECASE) ],
        [ "HOST", regex("(?<![\\p{L}\\p{N}.@#{EDGE}-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+(?:#{PRIVATE_SUFFIXES.join('|')})(?![\\p{L}\\p{N}.#{EDGE}-])") ],
        # Mixed case needs two labels before the suffix, so a method call like Time.local isn't a host.
        [ "HOST", regex("(?<![\\p{L}\\p{N}.@#{EDGE}-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.){2,}(?:#{PRIVATE_SUFFIXES.join('|')})(?![\\p{L}\\p{N}.#{EDGE}-])",
                        Regexp::IGNORECASE) ],
        [ "PATH", regex("(?<![\\p{L}\\p{N}.~/:#{EDGE}])/(?:[\\w.@+-]+/)+[\\w.@+-]+") ],
        [ "PATH", regex("(?<![\\p{L}\\p{N}/#{EDGE}])~/[\\w.@+/-]+") ],
        # Windows paths, with \\ separators too (a path inside JSON data, as the judge sends it).
        [ "PATH", regex('\b[A-Za-z]:\\\\{1,2}(?:[^\\\\\s"\'<>|*?]+\\\\{1,2})*[^\\\\\s"\'<>|*?]*') ]
      ].freeze
      HOME_OWNERS = [ regex('/home/([^/\s]+)/'), regex('/Users/([^/\s]+)/'), regex('\b[A-Za-z]:\\\\{1,2}Users\\\\{1,2}([^\\\\\s"]+)\\\\') ].freeze

      module_function

      # @param text [String]
      # @return [Array<String>] the usernames in its home-directory paths
      def owners(text)
        HOME_OWNERS.flat_map { |pattern| text.scan(pattern).flatten }.uniq
      end

      # @param text [String] a data segment (tokens already in it pass through)
      # @param tokens [Tokens]
      # @param counts [Hash{String => Integer}] incremented per token type
      # @return [Array(String, Integer)] the masked text and the number of secrets redacted
      def mask(text, tokens, counts)
        secrets = 0
        redact = lambda do |*|
          secrets += 1
          Tokens::SECRET
        end
        text = SECRETS.reduce(text) { |memo, pattern| memo.gsub(pattern, &redact) }
        text = text.gsub(ENTROPY) { |run| random?(run) ? redact.call : run }
        text = TYPED.reduce(text) do |memo, (type, pattern)|
          memo.gsub(pattern) do |match|
            counts[type] += 1
            tokens.for(type, match)
          end
        end
        [ text, secrets ]
      end

      # @param text [String] masked text with its tokens taken out
      # @return [Boolean] whether any pattern still matches (a leftover)
      def hit?(text)
        SECRETS.any? { |pattern| pattern.match?(text) } || text.scan(ENTROPY).any? { |run| random?(run) } ||
          TYPED.any? { |_, pattern| pattern.match?(text) }
      end

      # Long hex (either case), lowercase letters with many digits (base36 keys), or upper, lower and
      # digits switching often without lowercase words (an identifier, a path or snake_case has
      # long runs of one kind).
      # Separators (/ - _ + =) are ignored.
      def random?(run)
        chars = run.delete("/_+=-")
        return false if chars.length < 24
        return chars.match?(/\d/) && chars.match?(/[a-f]/i) if chars.match?(/\A(?:[0-9a-f]+|[0-9A-F]+)\z/)
        return chars.count("0-9") * 5 >= chars.length if chars.match?(/\A[a-z0-9]+\z/)

        classes = chars.chars.map { |char| char.match?(/[A-Z]/) ? 0 : char.match?(/[a-z]/) ? 1 : 2 }
        # Names have lowercase words of 4+ letters; random base64 almost never does.
        words = chars.scan(/[a-z]{4,}/).sum(&:length)
        classes.uniq.size == 3 && classes.chunk_while { |a, b| a == b }.count >= chars.length * 0.45 && words < chars.length * 0.4
      end
    end
  end
end
