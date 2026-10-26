# frozen_string_literal: true

# Shared driver for system specs: headless Chrome with the browser console log enabled,
# so specs can assert there are no CSP violations (see CspConsoleHelpers).
module CspConsoleHelpers
  # Reading the log clears it.
  # @return [Array<String>] browser console messages about the Content Security Policy
  def csp_console_errors
    page.driver.browser.logs.get(:browser).map(&:message).grep(/Content Security Policy/i)
  end

  # Waits until the app's Stimulus controllers have connected (every shell page mounts nav
  # and toast), so violations raised while JavaScript boots reach the log before it's read.
  def wait_for_stimulus
    page.document.synchronize do
      connected = page.evaluate_script("!!window.Stimulus && window.Stimulus.controllers.length > 0")
      raise Capybara::ExpectationNotMet, "Stimulus not booted" unless connected
    end
  end

  # Signs in through the login form.
  # @param username [String]
  # @param password [String]
  def sign_in_through_form(username: OperatorAuthHelpers::TEST_OPERATOR_USERNAME,
                           password: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD)
    visit operator_login_path
    fill_in "username", with: username
    fill_in "password", with: password
    click_button "Sign in"
  end
end

RSpec.configure do |config|
  config.include CspConsoleHelpers, type: :system

  config.before(:each, type: :system) do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 800 ] do |options|
      options.add_option("goog:loggingPrefs", { browser: "ALL" })
    end
    Operator::SessionsController.cache_store.clear # the login rate limit counts every sign-in
  end
end
