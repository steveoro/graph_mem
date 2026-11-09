# frozen_string_literal: true

class RailsCodeMap
  # Whether a folder holds a Rails application or engine (1.75.0): an `app/` dir, plus `rails` or
  # `railties` among its declared gems (Gemfile or root gemspecs) or a `config/application.rb`.
  #
  #   RailsCodeMap::Detector.rails?("/path/to/goggles_db", gems: Set["rails"]) # => true
  module Detector
    RAILS_GEMS = %w[rails railties].freeze

    module_function

    # @param root [String]
    # @param gems [Set<String>] the declared gem names (RailsCodeMap::Gems.names)
    # @return [Boolean]
    def rails?(root, gems:)
      return false unless File.directory?(File.join(root, "app"))

      RAILS_GEMS.any? { |name| gems.include?(name) } || File.file?(File.join(root, "config", "application.rb"))
    end
  end
end
