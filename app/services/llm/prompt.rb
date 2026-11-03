# frozen_string_literal: true

module Llm
  # A prompt as an ordered list of labelled segments (agent-CLI train PR1): `trusted` text is
  # written by graph_mem (instructions, labels, ids), `data` text comes from the graph or the
  # files (observation text, entity and project names, file contents). `to_s` joins the segments
  # as they are, so a prompt built this way is the same String as before; PR2's anonymizer will
  # rewrite only the `data` segments.
  #
  #   prompt = Llm::Prompt.new.trusted("Project: ").data("Gadget Project").trusted("\n")
  #   prompt.to_s                      # => "Project: Gadget Project\n"
  #   prompt.segments.map(&:kind)      # => [:trusted, :data, :trusted]
  class Prompt
    # @!attribute kind [Symbol] :trusted or :data
    # @!attribute text [String]
    Segment = Data.define(:kind, :text)

    def initialize
      @segments = []
    end

    # @param text [#to_s] instructions written by graph_mem
    # @return [self]
    def trusted(text)
      add(:trusted, text)
    end

    # @param text [#to_s] text from the graph or the scanned files (untrusted)
    # @return [self]
    def data(text)
      add(:data, text)
    end

    # @return [Array<Segment>] the segments in order (a copy)
    def segments
      @segments.dup
    end

    # @return [String] the segments joined, unchanged
    def to_s
      @segments.map(&:text).join
    end

    private

    def add(kind, text)
      @segments << Segment.new(kind: kind, text: text.to_s)
      self
    end
  end
end
