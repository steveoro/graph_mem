# frozen_string_literal: true

module Operator
  class SessionsController < ApplicationController
    def new
      redirect_to root_path if operator_signed_in?
    end

    def create
      username, password = operator_credentials

      if ActiveSupport::SecurityUtils.secure_compare(params[:username].to_s, username.to_s) &&
         ActiveSupport::SecurityUtils.secure_compare(params[:password].to_s, password.to_s)
        session[:operator_signed_in] = true
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
  end
end
