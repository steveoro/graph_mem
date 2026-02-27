source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.2"

gem "propshaft" # The modern asset pipeline for Rails [https://github.com/rails/propshaft]

gem "mysql2"  # Use mysql as the database for Active Record
gem "sqlite3" # Use sqlite3 as an alternative for msg queues & jobs


gem "puma", ">= 5.0" # Use the Puma web server [https://github.com/puma/puma]

gem "importmap-rails" # Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "jbuilder" # Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "stimulus-rails" # Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "turbo-rails" # Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

gem "fast-mcp" # MCP Server implementation

gem "bootsnap", require: false # Reduces boot times through caching; required in config/boot.rb
# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false
# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Swagger/OpenAPI docs served at /api-docs (needed in all envs including production)
gem "rswag-api"
gem "rswag-ui"

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri mingw x64_mingw ]

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  gem "pry"
  gem "pry-rails"
  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
  # RSpec for testing
  gem "rspec"
  gem "rspec-rails"

  # Adds support for Capybara system testing and selenium driver
  gem "capybara"
  gem "selenium-webdriver"
  # Use rack-mini-profiler for performance analysis
  gem "rack-mini-profiler"

  # Rswag spec generation (only needed for dev/test)
  gem "rswag-specs"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
end

gem "tailwindcss-rails", "~> 4.3"
