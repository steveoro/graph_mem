# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # Fixed resources as a ResourceCatalog provider (MCP Apps step A2, 1.87.0): each is listed in
    # resources/list and read by its exact URI. The body is a callable, built on first read and
    # memoized for the life of the process. Knows nothing about any URI scheme: McpApps::Views
    # registers the ui:// views through it.
    #
    # @example
    #   provider = StaticResourceProvider.new([
    #     { uri: "synth://note", name: "synth_note", title: "Synth note", description: "A note",
    #       mime_type: "text/plain", meta: nil, body: -> { "hello" } }
    #   ])
    #   provider.read("synth://note") # => [{ uri: "synth://note", mimeType: "text/plain", text: "hello" }]
    class StaticResourceProvider
      KEYS = %i[uri name title description mime_type meta body].freeze

      # @param entries [Array<Hash>] each with exactly KEYS; `meta` (or nil) goes on the content item
      # @param listing [#call] builds the resources/list entry from an entry (default: MCP::Resource.new)
      # @raise [ArgumentError] on a missing or unknown key, a non-callable body or a duplicate URI
      def initialize(entries, listing: nil)
        @entries = entries.map { |entry| validate(entry) }.index_by { |entry| entry[:uri] }.freeze
        raise ArgumentError, "duplicate static resource URI" unless @entries.size == entries.size

        @listing = listing || ->(entry) { MCP::Resource.new(**entry.slice(:uri, :name, :title, :description, :mime_type)) }
        @bodies = {}
        @lock = Mutex.new
      end

      # @return [Array<MCP::Resource>] one listing per entry, in registration order
      def resources = @entries.values.map { |entry| @listing.call(entry) }

      # @return [Array<MCP::ResourceTemplate>] none
      def templates = []

      # @param uri [String]
      # @return [Boolean]
      def match?(uri) = @entries.key?(uri)

      # @param uri [String] a URI this provider matches
      # @return [Array<Hash>] one text content item, with `_meta` when the entry has meta
      def read(uri)
        entry = @entries.fetch(uri)
        [ MCP::Resource::TextContents.new(uri: uri, mime_type: entry[:mime_type], text: body(entry), meta: entry[:meta]).to_h ]
      end

      private

      def validate(entry)
        missing = KEYS - entry.keys
        unknown = entry.keys - KEYS
        raise ArgumentError, "static resource keys: missing #{missing}, unknown #{unknown}" if missing.any? || unknown.any?
        raise ArgumentError, "static resource body must respond to #call" unless entry[:body].respond_to?(:call)

        entry.dup.freeze
      end

      def body(entry)
        @lock.synchronize { @bodies[entry[:uri]] ||= entry[:body].call.to_s.freeze }
      end
    end
  end
end
