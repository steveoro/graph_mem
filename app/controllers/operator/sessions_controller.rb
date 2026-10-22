# frozen_string_literal: true

module Operator
  class SessionsController < ApplicationController
    rate_limit to: 10, within: 3.minutes, only: :create,
               with: -> { render :new, status: :too_many_requests,
                                  locals: { error: t("operator.sessions.too_many_attempts") } }

    def new
      redirect_to root_path and return if operator_signed_in?

      if production_fallback_credentials?
        Rails.logger.error(
          "[SessionsController] Production is running with default operator credentials. " \
          "Set OPERATOR_USERNAME / OPERATOR_PASSWORD or Rails credentials[:operator]."
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

      if ActiveSupport::SecurityUtils.secure_compare(params[:username].to_s, username.to_s) &&
         ActiveSupport::SecurityUtils.secure_compare(params[:password].to_s, password.to_s)
        reset_session
        session[:role]         = "operator"
        session[:user]         = username
        session[:signed_in_at] = Time.current.to_i
        session[:last_seen_at] = Time.current.to_i
        redirect_to session.delete(:operator_return_to) || root_path,
                    notice: t("operator.sessions.signed_in")
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

    def production_fallback_credentials?
      Rails.env.production? &&
        self.class.operator_password == "changeme" &&
        self.class.operator_username == "operator"
    end
  end
end
