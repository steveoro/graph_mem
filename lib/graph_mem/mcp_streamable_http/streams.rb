# frozen_string_literal: true

module GraphMem
  module McpStreamableHttp
    # SSE streams of Streamable HTTP sessions: register, pump, enqueue and close them.
    # Included by GraphMem::McpStreamableHttpTransport; relies on its instance state.
    module Streams
      private

      def register_stream(session, io, response_queue = nil)
        stream = {
          queue: SizedQueue.new(@stream_queue_size),
          response_queue: response_queue,
          io: io,
          closed: false,
          mutex: Mutex.new
        }

        registered = @sessions_mutex.synchronize do
          if session[:closed] || !@sessions[session[:id]].equal?(session)
            false
          else
            session[:streams] << stream
            session[:last_active_at] = monotonic_time
            true
          end
        end

        registered ? stream : nil
      end

      def unregister_stream(session, stream)
        @sessions_mutex.synchronize do
          session[:streams]&.delete(stream)
        end
      end

      def streamable_get_loop(session, stream, session_id)
        write_sse_headers(stream[:io], "Mcp-Session-Id" => session_id)

        loop do
          break if stream_closed?(stream)

          touch_session!(session)
          message = next_stream_message(stream)

          if message
            write_sse_message(stream[:io], message)
          else
            break if stream_closed?(stream)

            # No message waiting; send a keep-alive comment.
            write_sse_keep_alive(stream[:io])
            sleep 1
          end
        end
      rescue IOError, EOFError, SystemCallError
        @logger.info("Streamable SSE client #{session_id} disconnected")
      ensure
        unregister_stream(session, stream)
        close_stream(session, stream)
      end

      def next_stream_message(stream)
        [ stream[:response_queue], stream[:queue] ].compact.each do |queue|
          begin
            return queue.pop(true)
          rescue ThreadError
            next
          end
        end

        nil
      end

      def stream_closed?(stream)
        stream[:mutex].synchronize { stream[:closed] }
      end

      def close_stream(session, stream)
        return unless stream

        should_close = stream[:mutex].synchronize do
          if stream[:closed]
            false
          else
            stream[:closed] = true
            true
          end
        end
        return unless should_close

        [ stream[:queue], stream[:response_queue] ].compact.each do |queue|
          queue.close unless queue.closed?
        end
        close_io(stream[:io])
        unregister_stream(session, stream) if session
      end

      def close_io(io)
        return unless io

        io.close unless io.closed?
      rescue IOError, SystemCallError
        nil
      end

      def enqueue_stream(session, stream, message)
        return if stream_closed?(stream)

        stream[:queue].push(message, true)
      rescue ThreadError
        @logger.warn("Closing a slow Streamable HTTP SSE stream")
        close_stream(session, stream)
      end

      def broadcast_to_session_streams(session, message)
        streams = @sessions_mutex.synchronize do
          session[:closed] ? [] : session[:streams].dup
        end
        streams.each { |stream| enqueue_stream(session, stream, message) }
      end

      def broadcast_to_streamable_sessions(message)
        sessions = @sessions_mutex.synchronize { @sessions.values.dup }
        sessions.each { |session| broadcast_to_session_streams(session, message) }
      end

      def write_sse_headers(io, extra_headers = {})
        io.write("HTTP/1.1 200 OK\r\n")
        SSE_HEADERS.merge(extra_headers).each { |key, value| io.write("#{key}: #{value}\r\n") }
        io.write("\r\n")
        io.write(": SSE connection established\n\n")
        io.flush
      end

      def write_sse_message(io, message)
        json = message_to_json(message)
        io.write("event: message\ndata: #{json}\n\n")
        io.flush
      end

      def write_sse_keep_alive(io)
        io.write(": keep-alive\n\n")
        io.flush
      end
    end
  end
end
