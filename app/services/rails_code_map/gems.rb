# frozen_string_literal: true

require "prism"

class RailsCodeMap
  # The gem names a project declares (1.75.0): `gem "name"` calls in its Gemfile, and
  # `add_dependency` / `add_runtime_dependency` / `add_development_dependency` calls in the
  # gemspecs at its root. Read with Prism, never evaluated; a file that doesn't parse adds nothing.
  #
  #   RailsCodeMap::Gems.names("/path/to/project") # => #<Set: {"rails", "grape", "mysql2"}>
  module Gems
    GEMSPEC_CALLS = %i[add_dependency add_runtime_dependency add_development_dependency].freeze
    MAX_FILE_BYTES = 200_000

    module_function

    # @param root [String] the project folder
    # @param keep [#call, nil] `keep.call(absolute_path)` false skips a file (the scan's file filter)
    # @return [Set<String>] the declared gem names, downcased
    def names(root, keep: nil)
      files = [ File.join(root, "Gemfile") ] + Dir.glob("*.gemspec", base: root).sort.map { |name| File.join(root, name) }
      files.select { |path| File.file?(path) && (keep.nil? || keep.call(path)) }.each_with_object(Set.new) do |path, found|
        next if File.size(path) > MAX_FILE_BYTES

        parsed = Prism.parse_file(path)
        collect(parsed.value, found) if parsed.success?
      end
    end

    def collect(node, found)
      if node.is_a?(Prism::CallNode) && (name = gem_name(node))
        found << name.downcase
      end
      node.compact_child_nodes.each { |child| collect(child, found) }
    end

    # The first string argument of a `gem` call without receiver, or of a gemspec dependency call.
    def gem_name(call)
      return nil unless (call.name == :gem && call.receiver.nil?) || GEMSPEC_CALLS.include?(call.name)

      first = call.arguments&.arguments&.first
      first.unescaped.to_s.strip.presence if first.is_a?(Prism::StringNode)
    end
    private_class_method :collect, :gem_name
  end
end
