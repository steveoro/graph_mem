# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # The gem's stdio transport writing to an explicit IO, so bin/mcp_stdio_runner.rb can keep
    # $stdout pointed at stderr: a stray `puts` anywhere in the app can't corrupt the stream.
    class StdioTransport < MCP::Server::Transports::StdioTransport
      # @param server [MCP::Server]
      # @param output [IO] the real stdout, saved before it was redirected
      # @param max_line_bytes [Integer] a longer line ends the session (D7)
      def initialize(server, output:, max_line_bytes: OfficialMcp.max_request_bytes)
        super(server, max_line_bytes: max_line_bytes)
        @output = output
      end

      # @param message [Hash, String] one JSON-RPC message
      def send_response(message)
        @output.puts(message.is_a?(String) ? message : JSON.generate(message))
        @output.flush
      end
    end
  end
end
