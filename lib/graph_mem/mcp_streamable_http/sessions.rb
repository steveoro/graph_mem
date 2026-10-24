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

      # Minimal per-session state (GHSA-84m7 lesson): the negotiated version and the client's
      # name/version only, never the whole initialize payload.
      def build_session(session_id, protocol_version, client_info: nil)
        info = client_info.is_a?(Hash) ? client_info.slice(:name, :version).transform_values { |value| value.to_s[0, 200] } : {}
        {
          id: session_id,
          negotiated_protocol_version: protocol_version,
          client_info: info,
          streams: [],
          get_stream_reserved: false,
          active_requests: 0,
          last_active_at: monotonic_time,
          closed: false
        }
      end

      # §2.4: one GET stream per session. Reserved atomically before the socket is hijacked.
      #
      # @return [Boolean] false when the session already has (or is opening) a GET stream
      def reserve_get_stream(session)
        @sessions_mutex.synchronize do
          next false if session[:get_stream_reserved] || session[:closed]

          session[:get_stream_reserved] = true
        end
      end

      def release_get_stream(session)
        @sessions_mutex.synchronize { session[:get_stream_reserved] = false }
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
        @server.remove_subscriber(session[:id]) if @server.respond_to?(:remove_subscriber)
      end

      def session_expired_locked?(session, now)
        !session[:closed] &&
          session[:active_requests].zero? &&
          session[:streams].empty? &&
          now - session[:last_active_at] > @session_timeout
      end

      # At the session cap, closes the least recently active idle session (no request in flight,
      # no stream, no GET stream being opened), so a client that opens a session per call without
      # DELETE can't lock everyone else out until its sessions expire.
      #
      # @return [Boolean] true when a session was evicted, false when every session is busy
      def evict_idlest_session
        victim = @sessions_mutex.synchronize do
          idle = @sessions.values.select do |session|
            !session[:closed] && session[:active_requests].zero? && session[:streams].empty? &&
              !session[:get_stream_reserved]
          end
          idle.min_by { |session| session[:last_active_at] }&.tap do |session|
            session[:closed] = true
            @sessions.delete(session[:id])
          end
        end
        return false unless victim

        close_session(victim)
        @logger.info("Session cap reached: evicted the least recently active idle MCP session")
        true
      end

      # @param force [Boolean] run even if the reaper ran less than @reaper_interval ago (the
      #   session cap does this before refusing a new session)
      def reap_expired_sessions(force: false)
        return unless @reaper_mutex.try_lock

        expired_sessions = []
        begin
          now = monotonic_time
          return if !force && now - @last_reaped_at < @reaper_interval

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
