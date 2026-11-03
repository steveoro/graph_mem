# frozen_string_literal: true

require "open3"

# Agent-CLI train PR1, step A4: a fake LLM provider for specs, and a guard that fails any spec in
# which app code starts a process.

# A provider that records its calls and answers with a canned Hash (or a block's Hash), so a spec
# can drive a call site without stubbing SummaryGenerationClient or Net::HTTP.
#
#   fake = FakeProvider.new(result: { ok: true, text: "SynthWidget renders frames.", error: nil, latency_ms: 1.0 })
#   fake = FakeProvider.new { |prompt, style:, options:| { ok: true, text: answer_for(prompt), error: nil, latency_ms: 1.0 } }
#   with_llm_provider(fake) { SummarizerService.call(query: "SynthWidget") }
#   fake.calls.sole # => #<data FakeProvider::Call prompt="…", style="concise", options=nil>
class FakeProvider < Llm::Provider
  # @!attribute prompt [String]
  # @!attribute style [String]
  # @!attribute options [Hash, nil] nil when the call site passed none
  Call = Data.define(:prompt, :style, :options)

  DEFAULT_RESULT = { ok: true, text: "", error: nil, latency_ms: 1.0 }.freeze

  # @return [Array<Call>] the calls so far, in order
  attr_reader :calls

  # @param name [String] the provider name the Router adds to results and the usage line
  # @param available [Boolean] what Llm::Router.usable? answers while it is in place
  # @param result [Hash] the answer to every call (ignored with a block)
  # @yieldparam prompt [String]
  # @yieldparam style [String]
  # @yieldparam options [Hash, nil]
  # @yieldreturn [Hash] the answer to that call
  def initialize(name: "fake", available: true, result: DEFAULT_RESULT, &answer)
    super()
    @name = name
    @available = available
    @result = result
    @answer = answer
    @calls = []
  end

  # @return [String]
  attr_reader :name

  # @return [Boolean]
  def available? = @available

  # @return [String] a synthetic model name for the usage line
  def model = "fake-model"

  # @param prompt [String]
  # @param style [String]
  # @param options [Hash, nil]
  # @return [Hash] the canned or computed answer
  def generate(prompt, style:, options: nil)
    @calls << Call.new(prompt: prompt, style: style, options: options)
    @answer ? @answer.call(prompt, style: style, options: options) : @result
  end
end

# Spec helpers for the Llm layer.
module LlmSpecHelpers
  # Puts `provider` in place of the ollama provider (every task's chain in PR1) for the block.
  #
  # @param provider [Llm::Provider]
  # @return [Object] the block's value
  def with_llm_provider(provider)
    Llm::Registry.override(:ollama, provider)
    yield
  ensure
    Llm::Registry.reset_overrides!
  end

  # Captures the `[llm]` usage lines written while the block runs.
  #
  # @return [Array<Hash>] each line's JSON fields
  def llm_usage_lines
    lines = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
      lines << args.first if args.first.to_s.start_with?(Llm::UsageLog::PREFIX)
      original.call(*args, &block)
    end
    yield
    lines.map { |line| JSON.parse(line.delete_prefix("#{Llm::UsageLog::PREFIX} ")) }
  end
end

# Fails the example when code under app/ or lib/ starts a process: the Rails app only talks HTTP
# (agent-CLI plan, hard rule). It wraps Open3.*, Kernel#system / #spawn / #` (and Kernel.system
# etc.), Process.spawn and IO.popen, and checks the immediate caller's file, so spec, bin/ and gem
# callers pass (spec/bin/up_spec.rb, spec/docs/agent_text_sync_spec.rb, Capybara's drivers).
# lib/tasks/ is exempt: the operator rake tasks there (db:dump, db:restore) run mariadb-dump,
# also when DatabaseBackupJob invokes them; that predates the plan and stays as it is.
module SubprocessGuard
  # Raised in place of a process start from app code.
  class Blocked < StandardError; end

  GUARDED_DIRS = %w[app/ lib/].freeze
  EXEMPT_DIRS = %w[lib/tasks/].freeze
  KERNEL_METHODS = %i[system spawn `].freeze
  OPEN3_METHODS = %i[popen3 popen2 popen2e capture3 capture2 capture2e pipeline_rw pipeline_r pipeline_w pipeline_start pipeline].freeze

  @active = false

  class << self
    # @return [Boolean] whether the guard checks calls (true inside an example)
    attr_accessor :active

    # @param path [String, nil] a caller's file
    # @return [Boolean] true for a file under app/ or lib/ of this repo, lib/tasks/ excepted
    def guarded_path?(path)
      root = "#{Rails.root}/"
      return false unless path.to_s.start_with?(root)

      relative = path.to_s.delete_prefix(root)
      GUARDED_DIRS.any? { |dir| relative.start_with?(dir) } && EXEMPT_DIRS.none? { |dir| relative.start_with?(dir) }
    end

    # @param method [Symbol] the wrapped method
    # @param location [Thread::Backtrace::Location, nil] its caller
    # @return [void]
    # @raise [Blocked] when active and the caller is guarded
    def check!(method, location)
      path = location && (location.absolute_path || location.path)
      return unless active && guarded_path?(path)

      raise Blocked, "#{method} called from #{path.delete_prefix("#{Rails.root}/")}:#{location.lineno}: " \
                     "app code never starts a process; talk HTTP instead"
    end

    # @param methods [Array<Symbol>]
    # @param private_methods [Boolean] keep them private (Kernel's instance methods)
    # @return [Module] a module to prepend that checks, then calls the original
    def wrapper(methods, private_methods: false)
      Module.new do
        methods.each do |name|
          define_method(name) do |*args, **kwargs, &block|
            SubprocessGuard.check!(name, caller_locations(1, 1).first)
            super(*args, **kwargs, &block)
          end
          private name if private_methods
        end
      end
    end
  end

  Kernel.prepend(wrapper(KERNEL_METHODS, private_methods: true))
  Kernel.singleton_class.prepend(wrapper(KERNEL_METHODS))
  Process.singleton_class.prepend(wrapper(%i[spawn]))
  IO.singleton_class.prepend(wrapper(%i[popen]))
  Open3.singleton_class.prepend(wrapper(OPEN3_METHODS))
end

RSpec.configure do |config|
  config.include LlmSpecHelpers
  config.before { SubprocessGuard.active = true }
  config.after do
    SubprocessGuard.active = false
    Llm::Registry.reset_overrides!
  end
end
