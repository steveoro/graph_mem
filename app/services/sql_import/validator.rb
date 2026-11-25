# frozen_string_literal: true

require "digest"
require "strscan"

module SqlImport
  # Checks a graph_mem-sql script before anything of it runs, so an uploaded file can't run SQL of its
  # own: the size cap (before reading), the marker and a format version this app has, the header lines,
  # the body's SHA-256, the fixed part byte for byte against this app's SqlExport::Template of that
  # version (its pinned sql_mode line included), and a strict scan of the part between: only
  # `INSERT INTO gm_stage_<table> (<the template's columns>) VALUES` statements in the writer's exact
  # layout, made of NULL, numbers and quoted strings. Quoted strings are read with the backslash rules
  # connection.quote writes (\0 \n \r \\ \' \" \Z); any other backslash, a raw quote, a raw line
  # break, an executable comment (/*! /*M!) or a comment of any kind outside a string is refused.
  #
  #   script = SqlImport::Validator.validate_file("tmp/exports/synth_prj.sql")
  #   script.version         # => 1
  #   script.header["roots"] # => "SynthPrj (Project)"
  #   script.data_statements # => ["INSERT INTO gm_stage_meta (k, v) VALUES\n('format', '1'),...", ...]
  class Validator
    # Refused before reading (a constant, not a setting).
    MAX_BYTES = 50 * 1024 * 1024
    HEADER_LINES = 10
    MARKER = /\A-- graph_mem-sql v(\d+)\n/
    HEADER_LINE = /\A-- ([a-z][a-z0-9_]*): ([^[:cntrl:]]*)\n/
    NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:e[-+]?[0-9]+)?/i
    # A quoted string as connection.quote writes it: no raw quote, backslash, NUL, CR, LF or Ctrl-Z
    # inside, and only the escapes it produces.
    STRING = /'(?:[^'\\\x00\n\r\x1a]++|\\[0nr\\'"Z])*+'/
    EXECUTABLE_COMMENT = %r{/\*M?!}

    # Raised for a file that must not run; the message says why.
    class Invalid < StandardError; end

    # @!attribute version [Integer] the format version
    # @!attribute header [Hash{String => String}] the header fields ("app", "roots", "sha256", ...)
    # @!attribute data_statements [Array<String>] the staging INSERTs, without their `;`
    Script = Data.define(:version, :header, :data_statements)

    # @param path [String, Pathname]
    # @return [Script]
    # @raise [Invalid]
    def self.validate_file(path)
      size = File.size(path.to_s)
      raise Invalid, "the file is #{size} bytes, over the #{MAX_BYTES / 1024 / 1024} MB limit" if size > MAX_BYTES

      validate(File.binread(path.to_s))
    end

    # @param text [String] the whole script
    # @return [Script]
    # @raise [Invalid]
    def self.validate(text)
      new(text).script
    end

    # @param text [String]
    def initialize(text)
      raise Invalid, "the script is over the #{MAX_BYTES / 1024 / 1024} MB limit" if text.bytesize > MAX_BYTES

      @text = text.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "the script is not valid UTF-8" unless @text.valid_encoding?
      # The writer escapes every CR inside a string: a raw one means the line endings were changed.
      raise Invalid, "the script has CR characters (its line endings were changed to CRLF)" if @text.include?("\r")
    end

    # @return [Script]
    # @raise [Invalid]
    def script
      version, header, body = split_header
      template = SqlExport::Template.new(version)
      raise Invalid, "the pinned sql_mode would read strings without backslash escapes" if SqlExport::Template::SQL_MODE.include?("NO_BACKSLASH_ESCAPES")
      raise Invalid, "the body does not match its sha256 (the file was changed or cut)" unless Digest::SHA256.hexdigest(body) == header["sha256"]

      Script.new(version: version, header: header, data_statements: data_statements(body, template))
    end

    private

    def split_header
      match = @text.match(MARKER) or raise Invalid, "not a graph_mem-sql script (no '-- graph_mem-sql v<N>' first line)"
      version = match[1].to_i
      raise Invalid, "graph_mem-sql v#{version} is not known to this graph_mem (it reads v#{SqlExport::Template::MAX_SCHEMA.keys.join(', v')})" unless SqlExport::Template.known?(version)

      scanner = StringScanner.new(@text)
      scanner.skip(MARKER)
      header = {}
      until header.key?("sha256")
        raise Invalid, "the header has no sha256 line" if header.size >= HEADER_LINES || !scanner.scan(HEADER_LINE)

        raise Invalid, "the header holds an executable comment (/*! or /*M!)" if scanner[2].match?(EXECUTABLE_COMMENT)

        header[scanner[1]] = scanner[2]
      end
      raise Invalid, "the header's sha256 is not a SHA-256 digest" unless header["sha256"].match?(/\A\h{64}\z/)

      [ version, header, scanner.rest ]
    end

    # The fixed part must be this app's template byte for byte; what is between is scanned.
    def data_statements(body, template)
      before = template.before_data
      after = template.after_data
      unless body.bytesize >= before.bytesize + after.bytesize && body.start_with?(before) && body.end_with?(after)
        raise Invalid, "the fixed part of the script differs from graph_mem-sql v#{template.version} here (edited, or its sql_mode line changed)"
      end

      scan(body.byteslice(before.bytesize, body.bytesize - before.bytesize - after.bytesize).force_encoding(Encoding::UTF_8), template)
    end

    def scan(data, template)
      scanner = StringScanner.new(data)
      statements = []
      until scanner.eos?
        start = scanner.pos
        table = scanner.scan(/INSERT INTO (gm_stage_[a-z]+) \(/) && scanner[1]
        columns = table && template.columns(table)
        refuse(scanner, "an INSERT INTO a staging table") unless columns
        refuse(scanner, "the column list of #{table}") unless scanner.skip("#{columns.join(', ')}) VALUES\n")
        loop do
          tuple(scanner, columns.size)
          break if scanner.skip(";\n")

          refuse(scanner, "',' and a new line, or ';' and a new line") unless scanner.skip(",\n")
        end
        statements << data.byteslice(start, scanner.pos - start - 2)
      end
      statements
    end

    def tuple(scanner, arity)
      refuse(scanner, "'('") unless scanner.skip("(")
      arity.times do |index|
        refuse(scanner, "', '") if index.positive? && !scanner.skip(", ")
        refuse(scanner, "a literal (NULL, a number or a quoted string)") unless scanner.skip(/NULL|#{NUMBER}|#{STRING}/o)
      end
      refuse(scanner, "')' after #{arity} values") unless scanner.skip(")")
    end

    def refuse(scanner, expected)
      rest = scanner.rest
      found = rest.match?(/\A\s*(?:#{EXECUTABLE_COMMENT}|--|#|\/\*)/o) ? "a comment" : rest[0, 40].inspect
      line = scanner.string.byteslice(0, scanner.pos).count("\n") + 1
      raise Invalid, "line #{line} of the data part: expected #{expected}, found #{found}"
    end
  end
end
