# frozen_string_literal: true

module GraphMem
  module McpStreamableHttp
    # Session bookkeeping for the Streamable HTTP transport: create, lease, release, close and reap sessions.
    # Included by GraphMem::McpStreamableHttpTransport; relies on its instance state.
    module Sessions
      private

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def build_session(session_id, protocol_version)
        {
          id: session_id,
          requested_protocol_version: protocol_version,
          streams: [],
          active_requests: 0,
          last_active_at: monotonic_time,
          closed: false
        }
      end

      def lease_existing_session(session_id)
        expired_session = nil
        session = @sessions_mutex.synchronize do
          candidate = @sessions[session_id]
          if candidate.nil? || candidate[:closed]
            nil
          elsif session_expired_locked?(candidate, monotonic_time)
            candidate[:closed] = true
            @sessions.delete(session_id) if @sessions[session_id].equal?(candidate)
            expired_session = candidate
            nil
          else
            candidate[:active_requests] += 1
            candidate[:last_active_at] = monotonic_time
            candidate
          end
        end

        close_session(expired_session) if expired_session
        return [ nil, :expired ] if expired_session
        return [ nil, :missing ] unless session

        [ session, nil ]
      end

      def release_session(session)
        @sessions_mutex.synchronize do
          session[:active_requests] -= 1 if session[:active_requests].positive?
          session[:last_active_at] = monotonic_time unless session[:closed]
        end
      end

      def touch_session!(session)
        @sessions_mutex.synchronize do
          session[:last_active_at] = monotonic_time unless session[:closed]
        end
      end

      def session_for_id(session_id)
        return unless session_id

        @sessions_mutex.synchronize do
          session = @sessions[session_id]
          session unless session&.[](:closed)
        end
      end

      def remove_session(session_id)
        @sessions_mutex.synchronize do
          session = @sessions[session_id]
          next unless session

          session[:closed] = true
          @sessions.delete(session_id) if @sessions[session_id].equal?(session)
          session
        end
      end

      def close_session(session)
        return unless session

        streams = @sessions_mutex.synchronize do
          session[:closed] = true
          streams = session[:streams].dup
          session[:streams].clear
          streams
        end
        streams.each { |stream| close_stream(nil, stream) }
      end

      def session_expired_locked?(session, now)
        !session[:closed] &&
          session[:active_requests].zero? &&
          session[:streams].empty? &&
          now - session[:last_active_at] > @session_timeout
      end

      def reap_expired_sessions
        return unless @reaper_mutex.try_lock

        expired_sessions = []
        begin
          now = monotonic_time
          return if now - @last_reaped_at < @reaper_interval

          @last_reaped_at = now
          @sessions_mutex.synchronize do
            @sessions.each do |session_id, session|
              next unless session_expired_locked?(session, now)
              next unless @sessions[session_id].equal?(session)

              session[:closed] = true
              @sessions.delete(session_id)
              expired_sessions << [ session_id, session ]
            end
          end
        ensure
          @reaper_mutex.unlock
        end

        expired_sessions.each { |_session_id, session| close_session(session) }
        @logger.info("Reaped #{expired_sessions.size} expired MCP sessions") if expired_sessions.any?
      end
    end
  end
end
