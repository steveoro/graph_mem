# frozen_string_literal: true

module Operator
  class SessionsController < ApplicationController
    layout "auth"
    allow_guest :destroy

    # A guest's stored return path is honoured only under these pages (they can reach them).
    GUEST_RETURN_PATH = %r{\A/(search|graph)(?:[/?]|\z)}

    rate_limit to: 10, within: 3.minutes, only: :create,
               with: -> {
                 flash.now[:alert] = t("operator.sessions.too_many_attempts")
                 render :new, status: :too_many_requests
               }

    def new
      redirect_to root_path and return if operator_signed_in?
      redirect_to search_path and return if guest_signed_in?

      if production_fallback_credentials?
        Rails.logger.error(
          "[SessionsController] Production is running with the default operator password. " \
          "Set OPERATOR_PASSWORD (or Rails credentials `operator.password`) to something other than `changeme`."
        )
        render :fallback_credentials_error, status: :service_unavailable
        nil
      end
    end

    def create
      if production_fallback_credentials?
        render :fallback_credentials_error, status: :service_unavailable
        return
      end

      username, password = operator_credentials
      username_match = ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(params[:username].to_s),
        Digest::SHA256.hexdigest(username.to_s)
      )
      password_match = ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(params[:password].to_s),
        Digest::SHA256.hexdigest(password.to_s)
      )
      # Always checked (random values when no guest is available), so timing doesn't
      # reveal whether a guest account exists. The operator match wins.
      guest = GraphMem::GuestCredentials.current
      guest_match = guest.matches?(params[:username], params[:password])

      if username_match & password_match
        return_to = start_session!(role: "operator", user: username)
        redirect_to return_to || root_path, notice: t("operator.sessions.signed_in")
      elsif guest_match
        return_to = start_session!(role: "guest", user: guest.username)
        session[:guest_cred_fp] = guest.fingerprint
        redirect_to(return_to.to_s.match?(GUEST_RETURN_PATH) ? return_to : search_path,
                    notice: t("operator.sessions.signed_in"))
      else
        flash.now[:alert] = t("operator.sessions.invalid_credentials")
        render :new, status: :unprocessable_content
      end
    end

    def destroy
      reset_session
      redirect_to operator_login_path, notice: t("operator.sessions.signed_out")
    end

    private

    # Starts a fresh session (new id) for the role.
    # @return [String, nil] the return path stored before sign-in
    def start_session!(role:, user:)
      return_to = session[:operator_return_to]
      reset_session
      now = Time.current.to_i
      session[:role]         = role
      session[:user]         = user
      session[:signed_in_at] = now
      session[:last_seen_at] = now
      return_to
    end

    # The default username ("operator") is public and documented; only the
    # default password is a risk, so only that locks production out.
    def production_fallback_credentials?
      Rails.env.production? && self.class.operator_password == "changeme"
    end
  end
end
