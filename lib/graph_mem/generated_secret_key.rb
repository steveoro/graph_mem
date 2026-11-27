# frozen_string_literal: true

require "pathname"

module GraphMem
  # The secret_key_base of a production container that has neither SECRET_KEY_BASE nor a master key
  # (#206).
  #
  # bin/docker-entrypoint generates +storage/secret_key_base+ (128 hex characters, mode 0600) when
  # the server first boots and exports it to the server. config/environments/production.rb calls
  # {.apply} so that every other process in the container (`docker compose exec app bin/rails ...`
  # skips the entrypoint) reads the same key. When SECRET_KEY_BASE or a master key is set, nothing
  # changes: Rails takes SECRET_KEY_BASE, or the credentials' secret_key_base, as before.
  #
  #   GraphMem::GeneratedSecretKey.apply(config) # in Rails.application.configure
  module GeneratedSecretKey
    # Relative to the app root. Keep it in step with GENERATED_KEY_FILE in bin/docker-entrypoint.
    PATH = "storage/secret_key_base"

    module_function

    # Removes an empty SECRET_KEY_BASE from +env+: compose passes "" when .env has none, and Rails
    # would take "" as an invalid key instead of reading the credentials. Then sets
    # +config.secret_key_base+ to the generated key, if {.read} finds one.
    #
    # @param config [#secret_key_base=] the application configuration
    # @param env [ENV, Hash{String => String}]
    # @param root [Pathname] the application root
    # @return [Boolean] whether the generated key was applied
    def apply(config, env: ENV, root: Rails.root)
      env.delete("SECRET_KEY_BASE") if env["SECRET_KEY_BASE"] == ""
      key = read(env: env, root: root)
      config.secret_key_base = key if key
      !key.nil?
    end

    # Same test as bin/docker-entrypoint: SECRET_KEY_BASE, RAILS_MASTER_KEY and config/master.key
    # are all missing (an empty variable counts as missing).
    #
    # @param env [ENV, Hash{String => String}]
    # @param root [Pathname] the application root
    # @return [Boolean]
    def needed?(env: ENV, root: Rails.root)
      env["SECRET_KEY_BASE"].to_s.empty? && env["RAILS_MASTER_KEY"].to_s.empty? &&
        !root.join("config/master.key").exist?
    end

    # @param env [ENV, Hash{String => String}]
    # @param root [Pathname] the application root
    # @return [String, nil] the generated key; nil when another key source is set ({.needed?} is
    #   false) or no key was generated yet
    def read(env: ENV, root: Rails.root)
      return unless needed?(env: env, root: root)

      path = root.join(PATH)
      key = path.read.strip if path.file?
      key unless key.nil? || key.empty?
    end
  end
end
