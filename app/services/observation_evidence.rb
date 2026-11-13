# frozen_string_literal: true

# Decides whether an observation content that two entities share is distinctive enough to count
# as evidence that they are related or the same thing. Boilerplate ("Status: Completed",
# "Successfully refactored to use fast-mcp syntax.") sits on dozens of entities and proves nothing.
#
# Content is distinctive when ALL of these hold:
# - it is at least {MIN_LENGTH} characters;
# - it is not a "Key: value" metadata line ({METADATA_LINE});
# - at most {MAX_HOLDERS} entities hold it as an active observation.
#
# Producers should call {.distinctive_contents} once per set of contents: it runs one grouped
# count query per batch, never one per pair.
#
# @example
#   ObservationEvidence.distinctive_contents(shared_contents) # => Set of the contents worth counting
#   ObservationEvidence.distinctive?("Status: Completed")     # => false
class ObservationEvidence
  MIN_LENGTH = 40
  MAX_HOLDERS = 2
  METADATA_LINE = /\A[\w ]{2,20}:\s/
  BATCH_SIZE = 500

  class << self
    # @param content [String, nil] one observation content
    # @return [Boolean] whether the content is distinctive (see the class comment)
    def distinctive?(content)
      distinctive_contents([ content ]).any?
    end

    # @param contents [Enumerable<String>] observation contents (duplicates and nils are ignored)
    # @return [Set<String>] the subset of +contents+ that counts as evidence, as given by the caller
    def distinctive_contents(contents)
      candidates = contents.compact.uniq.select { |content| plausible?(content) }
      return Set.new if candidates.empty?

      counts = holder_counts(candidates)
      # A content the count query did not return (collation quirk) is held by the caller at least.
      candidates.select { |content| counts.fetch(normalize(content), 1) <= MAX_HOLDERS }.to_set
    end

    private

    # Cheap checks that need no query.
    def plausible?(content)
      text = content.to_s
      text.length >= MIN_LENGTH && !METADATA_LINE.match?(text)
    end

    # One grouped query per batch: how many distinct entities hold each content as active.
    # @return [Hash{String => Integer}] keyed by the normalized content (the column is case-insensitive)
    def holder_counts(contents)
      contents.each_slice(BATCH_SIZE).each_with_object({}) do |slice, counts|
        MemoryObservation.active.where(content: slice).group(:content).distinct.count(:memory_entity_id)
                         .each { |content, holders| counts[normalize(content)] = holders }
      end
    end

    def normalize(content)
      content.to_s.downcase.strip
    end
  end
end
