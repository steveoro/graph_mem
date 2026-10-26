return unless defined?(Rswag::Ui)

Rswag::Ui.configure do |c|
  c.swagger_endpoint "/api-docs/v1/swagger.yaml", "API V1 Docs"
end

# Override rswag-ui's hardcoded CSP to allow API connections from any access
# origin. The gem's default CSP omits connect-src (falling back to
# default-src 'self'), which blocks Swagger "Try it out" calls when the page
# is accessed via a different hostname than the spec's server URL.
Rswag::Ui::Middleware.class_eval do
  private

  def csp
    <<~POLICY.tr("\n", " ")
      default-src 'self';
      connect-src 'self' http://localhost:3030;
      img-src 'self' data: https://validator.swagger.io;
      font-src 'self' https://fonts.gstatic.com;
      style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
      script-src 'self' 'unsafe-inline';
    POLICY
  end
end

# Rack 3 header names are lowercase. rswag-ui 2.17 returns its index page with a
# mixed-case "Content-Security-Policy" key, which Rails' CSP middleware doesn't
# recognise, so it would add the app's enforced policy on top and block Swagger UI's
# inline scripts. Lowercasing the keys lets Rails leave rswag's own policy alone.
module RswagUiLowercaseHeaders
  def call(env)
    status, headers, body = super
    [ status, headers.to_h.transform_keys { |key| key.to_s.downcase }, body ]
  end
end
Rswag::Ui::Middleware.prepend(RswagUiLowercaseHeaders)
