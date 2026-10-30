# frozen_string_literal: true

class ProjectScanner
  # Splits the files a scan discovered into parts that each fit the model's window (F-3).
  # Pure apart from reading the realpaths it is handed (ProjectScanner#discover_files already
  # checked them). Nothing is dropped silently: a file over max_file_bytes counts as
  # `files_too_large`, and a file past the total-bytes cap or the part cap counts as
  # `files_over_budget`; both are listed in `left_out`.
  #
  # Order: README and manifests first, then the root files, then the other files grouped by
  # their top-level directory, each group by path. Whole files are packed greedily; a file larger
  # than a part is split at line boundaries into pieces labelled "(part k of m)".
  #
  #   plan = ProjectScanner::ChunkPlanner.new(files: paths, root: "/path/to/project", input_budget: 4900).call
  #   plan.chunks.map(&:index) # => [1, 2, 3]
  #   plan.context_text        # => every part's text, for the validator
  class ChunkPlanner
    # Below this many tokens a part can't hold a useful share of the files: the scan falls back.
    MIN_INPUT_BUDGET = 1024
    LEFT_OUT_LIMIT = 50
    # Room for the "(part k of m)" label of a split file's piece.
    PIECE_LABEL_BYTES = 32

    # `pieces` are the "--- FILE: …" blocks; a failed part is split between them (ChunkedExtraction).
    Chunk = Data.define(:index, :files, :pieces, :estimated_tokens) do
      def text = pieces.join("\n")
    end
    Plan = Data.define(:chunks, :context_text, :files_read, :files_too_large, :files_over_budget, :left_out,
                       :input_budget, :error)

    README_PATTERN = /\Areadme/i

    # @param path [String]
    # @return [Boolean] a manifest the deterministic fallback lists and the planner sends first
    def self.manifest_file?(path)
      name = File.basename(path).downcase
      %w[package.json gemfile gemfile.lock pyproject.toml cargo.toml go.mod .devin].include?(name) ||
        name.start_with?("requirements", "docker-compose")
    end

    # @param files [Array<String>] realpaths under root
    # @param root [String, Pathname] the project root's realpath
    # @param input_budget [Integer] estimated tokens per part (TokenEstimate.input_budget)
    # @param max_chunks [Integer] the most parts
    # @param max_file_bytes [Integer] larger files are skipped and counted
    # @param max_total_bytes [Integer] reading stops here; the rest is counted
    # @param bytes_per_token [Numeric] the estimate (TokenEstimate)
    def initialize(files:, root:, input_budget:, max_chunks: 16, max_file_bytes: ProjectScanner::MAX_FILE_BYTES,
                   max_total_bytes: ProjectScanner::MAX_TOTAL_INPUT_BYTES, bytes_per_token: TokenEstimate::BYTES_PER_TOKEN)
      @root = Pathname.new(root.to_s)
      @files = Array(files)
      @input_budget = input_budget.to_i
      @max_chunks = [ max_chunks.to_i, 1 ].max
      @max_file_bytes = max_file_bytes.to_i
      @max_total_bytes = max_total_bytes.to_i
      @bytes_per_token = bytes_per_token
      @budget_bytes = TokenEstimate.bytes(@input_budget, bytes_per_token: bytes_per_token)
    end

    # @return [Plan] `error` is :window_too_small (and no chunks) when input_budget < MIN_INPUT_BUDGET
    def call
      return plan(error: :window_too_small) if @input_budget < MIN_INPUT_BUDGET

      @chunks = []
      @open = nil
      @read = []
      @too_large = 0
      @over_budget = 0
      @left_out = []
      pack(read_files(ordered))
      close_open
      plan
    end

    private

    def plan(error: nil)
      chunks = @chunks || []
      Plan.new(chunks: chunks, context_text: chunks.map(&:text).join("\n"), files_read: (@read || []).uniq.size,
               files_too_large: @too_large.to_i, files_over_budget: @over_budget.to_i,
               left_out: (@left_out || []).first(LEFT_OUT_LIMIT), input_budget: @input_budget, error: error)
    end

    def ordered
      @files.map { |path| [ path, relative(path) ] }.sort_by do |_path, rel|
        top, rest = rel.split("/", 2)
        first = README_PATTERN.match?(File.basename(rel)) || self.class.manifest_file?(rel) ? 0 : 1
        [ first, rest ? 1 : 0, rest ? top : "", rel ]
      end
    end

    # @return [Array<Array(String, String)>] `[relative, content]` within the size caps
    def read_files(entries)
      total = 0
      entries.each_with_object([]) do |(path, rel), kept|
        if total > @max_total_bytes
          leave_out(rel)
          next
        end
        if File.size(path) > @max_file_bytes
          @too_large += 1
          @left_out << rel
          next
        end

        # scrub: encode to the same encoding leaves invalid bytes in place.
        content = File.binread(path).force_encoding("UTF-8").scrub
        total += snippet(rel, content).bytesize
        total > @max_total_bytes ? leave_out(rel) : kept << [ rel, content ]
      end
    end

    def pack(entries)
      entries.each_with_index do |(rel, content), position|
        text = snippet(rel, content)
        next add(rel, text) if fits?(text)

        pieces = text.bytesize > @budget_bytes ? split(rel, content) : [ text ]
        if @chunks.size + (@open ? 1 : 0) + pieces.size > @max_chunks
          entries.drop(position).each { |(left, _)| leave_out(left) }
          break
        end

        pieces.each do |piece|
          close_open
          add(rel, piece)
        end
      end
    end

    def fits?(text)
      @open && @open[:bytes] + 1 + text.bytesize <= @budget_bytes
    end

    def add(rel, text)
      @open ||= { files: [], texts: [], bytes: -1 }
      @open[:files] << rel unless @open[:files].include?(rel)
      @open[:texts] << text
      @open[:bytes] += 1 + text.bytesize
      @read << rel
    end

    def close_open
      return unless @open

      pieces = @open[:texts]
      @chunks << Chunk.new(index: @chunks.size + 1, files: @open[:files], pieces: pieces, estimated_tokens: TokenEstimate.tokens(pieces.join("\n"), bytes_per_token: @bytes_per_token))
      @open = nil
    end

    def leave_out(rel)
      @over_budget += 1
      @left_out << rel
    end

    def snippet(rel, content, label = nil)
      "--- FILE: #{rel}#{" (#{label})" if label}\n#{content}\n---\n"
    end

    # A file larger than one part: pieces at line boundaries (a single over-long line at the byte
    # limit, on a UTF-8 boundary), each labelled "(part k of m)".
    def split(rel, content)
      # A floor, so a very long path can't leave no room for the body.
      limit = [ @budget_bytes - snippet(rel, "").bytesize - PIECE_LABEL_BYTES, 256 ].max
      bodies = content.each_line.each_with_object([ +"" ]) do |line, acc|
        line_pieces(line, limit).each do |piece|
          acc << +"" if acc.last.bytesize + piece.bytesize > limit && !acc.last.empty?
          acc.last << piece
        end
      end.reject(&:empty?)
      bodies.each_with_index.map { |body, i| snippet(rel, body.chomp, "part #{i + 1} of #{bodies.size}") }
    end

    def line_pieces(line, limit)
      pieces = []
      rest = line
      while rest.bytesize > limit
        cut = limit
        # Never down to 0: a zero cut wouldn't move `rest` forward.
        cut -= 1 until cut.zero? || rest.byteslice(0, cut).valid_encoding?
        cut = limit if cut.zero?
        pieces << rest.byteslice(0, cut)
        rest = rest.byteslice(cut..)
      end
      pieces << rest
    end

    def relative(path)
      Pathname.new(path).relative_path_from(@root).to_s
    end
  end
end
