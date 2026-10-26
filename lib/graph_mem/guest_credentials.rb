# frozen_string_literal: true

require "openssl"

module GraphMem
  # The read-only guest account (UI-1). Disabled unless a guest password is configured:
  # there is no default password anywhere.
  #
  # Resolution, per field: ENV (`GRAPH_MEM_GUEST_USERNAME` / `GRAPH_MEM_GUEST_PASSWORD`;
  # blank counts as unset, docker-compose passes "") → Rails credentials `guest.username` /
  # `guest.password` → username "guest", password nil. Resolved once per process
  # (`current`), so a rotated password takes effect after a restart.
  #
  # Usage:
  #   creds = GraphMem::GuestCredentials.current
  #   creds.available?   # configured, no clash with the operator, toggle on
  #   creds.fingerprint  # stored in the guest session; a new password invalidates it
  class GuestCredentials
    USERNAME_ENV = "GRAPH_MEM_GUEST_USERNAME"
    PASSWORD_ENV = "GRAPH_MEM_GUEST_PASSWORD"
    DEFAULT_USERNAME = "guest"
    UNREADABLE_CREDENTIALS = [
      ActiveSupport::MessageEncryptor::InvalidMessage,
      ActiveSupport::EncryptedFile::MissingKeyError
    ].freeze

    class << self
      # @param env [#[]] environment variables
      # @param credentials [#dig] a credentials store
      # @return [GuestCredentials] frozen
      def resolve(env: ENV, credentials: credentials_store)
        new(
          username: env[USERNAME_ENV].presence || credentials.dig(:guest, :username).presence || DEFAULT_USERNAME,
          password: env[PASSWORD_ENV].presence || credentials.dig(:guest, :password).presence
        )
      end

      # Rails credentials, or {} when the file can't be decrypted ("not configured").
      # @return [#dig]
      def credentials_store
        store = Rails.application.credentials
        store.config # decrypt now, so an unreadable file is handled here
        store
      rescue *UNREADABLE_CREDENTIALS => e
        Rails.logger.warn("[guest access] credentials unreadable (#{e.class}); guest treated as not configured")
        {}
      end

      # @return [GuestCredentials] resolved once per process
      def current
        @current ||= resolve
      end

      # Forget the memoised value (specs, or after changing ENV in a console).
      # @return [void]
      def reset!
        @current = nil
      end
    end

    attr_reader :username

    # @param username [String]
    # @param password [String, nil]
    def initialize(username:, password:)
      @username = username.to_s.dup.freeze
      @password = password&.to_s&.dup&.freeze
      freeze
    end

    # @return [Boolean] a guest password is set
    def configured?
      @password.present?
    end

    # The guest must never share the operator's username or password.
    # @return [Boolean]
    def collides_with_operator?
      same?(@username, ApplicationController.operator_username) |
        same?(@password, ApplicationController.operator_password)
    end

    # @return [Boolean] guests may sign in
    def available?
      configured? && !collides_with_operator? && AppSettings.guest_access_enabled?
    end

    # @return [Symbol] :not_configured, :conflict, :disabled or :available
    def status
      return :not_configured unless configured?
      return :conflict if collides_with_operator?
      return :disabled unless AppSettings.guest_access_enabled?

      :available
    end

    # Checks a sign-in attempt in constant time. When the guest isn't available it compares
    # against random values, so the work (and timing) is the same either way.
    #
    # @param username [String]
    # @param password [String]
    # @return [Boolean]
    def matches?(username, password)
      usable = available?
      expected_user = usable ? @username : SecureRandom.hex(32)
      expected_password = usable ? @password : SecureRandom.hex(32)
      (same?(username, expected_user) & same?(password, expected_password)) && usable
    end

    # HMAC of the credentials with secret_key_base (32 hex chars). Stored in the guest's
    # session; when the password changes, existing guest sessions stop matching.
    # @return [String]
    def fingerprint
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "#{@username}\0#{@password}")[0, 32]
    end

    def inspect
      "#<#{self.class.name} username=#{@username.inspect} configured=#{configured?}>"
    end
    alias_method :to_s, :inspect

    private

    def same?(given, expected)
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(given.to_s), Digest::SHA256.hexdigest(expected.to_s)
      )
    end
  end
end
