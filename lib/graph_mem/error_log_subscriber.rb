# frozen_string_literal: true

module GraphMem
  # Logs handled `Rails.error.report` calls (MCP internal errors, a failing Home widget), which
  # otherwise reach no one: ActiveSupport::ErrorReporter only calls its subscribers. Unhandled
  # reports are skipped because Rails already logs them (requests, jobs).
  #
  # The line carries the error class, message, source and a reduced context: MCP request context
  # keeps only the JSON-RPC method and the tool name (never the arguments), everything else goes
  # through the app's parameter filter, and the context is cut to CONTEXT_LIMIT characters.
  #
  #   Rails.error.subscribe(GraphMem::ErrorLogSubscriber.new)
  #   Rails.error.report(error, handled: true, context: { home_section: :digest })
  #   # => "Handled error: ActiveRecord::StatementInvalid: ... source=application context={...}"
  class ErrorLogSubscriber
    CONTEXT_LIMIT = 500
    MAX_DEPTH = 4
    FAILURE_LINE = "GraphMem::ErrorLogSubscriber failed to log a handled error"

    # @param logger [#error, nil] defaults to Rails.logger at report time
    def initialize(logger: nil)
      @logger = logger
    end

    # The ActiveSupport::ErrorReporter subscriber interface. Never raises.
    #
    # @param error [Exception]
    # @param handled [Boolean]
    # @param severity [Symbol]
    # @param context [Hash]
    # @param source [String, nil]
    # @return [void]
    def report(error, handled:, severity:, context:, source: nil)
      return unless handled

      logger.error("Handled error: #{error.class}: #{error.message} source=#{source} context=#{reduced_context(context)}")
    rescue StandardError
      begin
        Rails.logger.error(FAILURE_LINE)
      rescue StandardError
        nil
      end
    end

    private

    def logger
      @logger || Rails.logger
    end

    def reduced_context(context)
      context = context.to_h.dup
      context[:mcp] = reduced_mcp(context[:mcp]) if context.key?(:mcp)
      filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(plain(context))
      filtered.to_json.truncate(CONTEXT_LIMIT)
    end

    # Plain values only: Rails adds its execution context (the controller, the request), so any
    # other object is shown by its class name instead of being serialized.
    def plain(value, depth = 0)
      case value
      when Hash then depth < MAX_DEPTH ? value.to_h { |key, item| [ key.to_s, plain(item, depth + 1) ] } : "Hash"
      when Array then depth < MAX_DEPTH ? value.first(10).map { |item| plain(item, depth + 1) } : "Array"
      when String, Symbol, Numeric, true, false, nil then value
      else value.class.name
      end
    end

    # The gem passes `{ request: <JSON-RPC request> }` (or a notification name): keep the method and
    # the tool name, drop params and arguments, which can carry observation text.
    def reduced_mcp(mcp)
      mcp = mcp.to_h.transform_keys(&:to_sym)
      request = mcp.delete(:request)
      return mcp unless request

      reduced = request.is_a?(Hash) ? reduced_request(request.transform_keys(&:to_sym)) : {}
      mcp.merge(request: reduced)
    end

    def reduced_request(request)
      params = request[:params]
      name = params.is_a?(Hash) ? (params[:name] || params["name"]) : nil
      { method: request[:method], name: name }.compact
    end
  end
end
