require_relative "boot"

require "rails/all"
require "active_support/core_ext/string/inflections"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module GraphMem
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Permit loading YAML files with aliases
    config.yaml_aliases_permitted_for_all_loaders = true

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
    config.eager_load_paths << Rails.root.join("app/mcp")
    # config.eager_load_paths << Rails.root.join("lib")

    # For example, in the context of Relations, ensure that associated MemoryEntity objects are preloaded
    # when retrieving multiple relations to avoid N+1 query issues.
    # config.active_record.verbose_query_logs = true

    # === Add lib to autoload paths ===
    config.autoload_paths << Rails.root.join("lib")
  end
end
