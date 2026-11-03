# frozen_string_literal: true

module Llm
  # Looks up a provider by name. PR1 has one, `:ollama`. Specs swap one in with `override`
  # (spec/support/llm.rb resets it after each example); outside the test environment
  # `override` raises, so production code can't replace a provider.
  #
  #   Llm::Registry.fetch(:ollama)               # => #<Llm::OllamaProvider>
  #   Llm::Registry.override(:ollama, fake)      # specs only
  #   Llm::Registry.reset_overrides!
  module Registry
    BUILT_IN = { ollama: OllamaProvider }.freeze

    @overrides = {}

    class << self
      # @param name [Symbol, String]
      # @return [Llm::Provider]
      # @raise [KeyError] for an unknown provider
      def fetch(name)
        key = name.to_sym
        @overrides.fetch(key) { BUILT_IN.fetch(key).new }
      end

      # @param name [Symbol, String] the provider to replace
      # @param provider [Llm::Provider, #generate] what `fetch(name)` returns until the reset
      # @return [void]
      # @raise [RuntimeError] outside the test environment
      def override(name, provider)
        raise "Llm::Registry.override is for specs only" unless Rails.env.test?

        @overrides[name.to_sym] = provider
      end

      # @return [void]
      def reset_overrides!
        @overrides = {}
      end
    end
  end
end
