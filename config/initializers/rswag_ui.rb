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
