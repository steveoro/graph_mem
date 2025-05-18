# config/initializers/yaml_unsafe_load_patch.rb

# Bypass Psych 4+ breaking change by restoring the old behavior of YAML.load
# This allows loading YAML files (like database.yml) with aliases without
# explicitly passing `aliases: true` everywhere.
# See: https://github.com/ruby/psych/issues/487
# Note: This uses `unsafe_load`. Ensure you trust the source of your YAML files.

require "yaml"

module YAML
  class << self
    # Check if `unsafe_load` exists (it was added in Psych 3.1)
    # and alias `load` to it if available.
    alias_method :load, :unsafe_load if YAML.respond_to?(:unsafe_load)
  end
end
