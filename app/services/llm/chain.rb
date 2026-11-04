# frozen_string_literal: true

module Llm
  # The chain values a llm_chain_<task> setting may hold, and the models each agent-CLI entry tries
  # (agent-CLI PR4, PR5). A chain is a list of names: `:ollama`, `:agent_cli` (PR4: the profile in
  # llm_agent_cli_profile), or a shipped profile (`:claude`, `:devin`, PR5), tried in order.
  # Within a profile entry the models run primary first, then up to three backups
  # (llm_profile_<name>_model, llm_profile_<name>_backup_models).
  #
  #   Llm::Chain.parse("claude,devin,ollama") # => [:claude, :devin, :ollama]
  #   Llm::Chain.models(:claude)              # => [["claude", "zq7-model"], ["claude", "zq7-backup"]]
  module Chain
    PROFILE_ORDERS = [ %w[claude], %w[devin], %w[claude devin], %w[devin claude] ].freeze
    # PR4's values, then each profile order alone and followed by ollama (a fixed list, not free text).
    VALUES = (%w[ollama agent_cli agent_cli,ollama ollama,agent_cli] +
              PROFILE_ORDERS.flat_map { |order| [ order.join(","), [ *order, "ollama" ].join(",") ] }).freeze
    PROFILE_ENTRIES = %i[agent_cli claude devin].freeze
    MAX_BACKUPS = 3

    module_function

    # @param value [String] a setting value
    # @return [Array<Symbol>, nil] the names, or nil for a value outside VALUES
    def parse(value)
      VALUES.include?(value.to_s) ? value.to_s.split(",").map(&:to_sym) : nil
    end

    # @param name [Symbol]
    # @return [Boolean] whether the name is an agent-CLI entry (expanded into profile models)
    def profile_entry?(name)
      PROFILE_ENTRIES.include?(name)
    end

    # The (profile, model) pairs an entry tries, in order. `:agent_cli` is PR4's single profile and
    # model, unless that profile has its own model field set (then the profile's fields win). A
    # blank or unknown profile or model still gives one pair (the provider answers
    # "bridge_not_configured", so the chain moves on as in 1.70.0).
    #
    # @param name [Symbol] one of PROFILE_ENTRIES
    # @return [Array<Array(String, String)>]
    def models(name)
      profile = name == :agent_cli ? AppSettings.llm_agent_cli_profile.to_s : name.to_s
      primary = profile_model(profile)
      return [ [ profile, AppSettings.llm_agent_cli_model.to_s ] ] if name == :agent_cli && primary.blank?

      [ primary.to_s, *backups(profile, primary) ].map { |model| [ profile, model ] }
    end

    # @param profile [String]
    # @return [String, nil] the profile's own primary model setting
    def profile_model(profile)
      return nil unless AgentCliProvider::PROFILES.include?(profile)

      AppSettings.public_send(:"llm_profile_#{profile}_model").to_s.strip.presence
    end

    # @param profile [String]
    # @param primary [String, nil]
    # @return [Array<String>] the valid backup models, in order, without the primary or repeats
    def backups(profile, primary = profile_model(profile))
      return [] unless primary && AgentCliProvider::PROFILES.include?(profile)

      list = split_models(AppSettings.public_send(:"llm_profile_#{profile}_backup_models"))
      (list.select { |model| model.match?(AgentCliProvider::MODEL_PATTERN) }.uniq - [ primary ]).first(MAX_BACKUPS)
    end

    # @param raw [String, nil] a comma-separated list
    # @return [Array<String>]
    def split_models(raw)
      raw.to_s.split(",").map(&:strip).reject(&:empty?)
    end
  end
end
