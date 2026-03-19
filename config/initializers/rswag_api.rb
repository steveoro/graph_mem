return unless defined?(Rswag::Api)

Rswag::Api.configure do |c|
  # Specify a root folder where Swagger JSON files are located
  # This is used by the Swagger middleware to serve requests for API descriptions
  # NOTE: If you're using rswag-specs to generate Swagger, you'll need to ensure
  # that it's configured to generate files in the same folder
  c.openapi_root = Rails.root.to_s + "/swagger"

  # Dynamically set the server URL to match the request origin so "Try it out"
  # works regardless of whether the page is accessed via localhost, LAN IP, etc.
  c.swagger_filter = lambda { |swagger, env|
    host = env["HTTP_HOST"]
    scheme = env["rack.url_scheme"] || "http"
    swagger["servers"] = [
      { "url" => "#{scheme}://#{host}", "description" => "Current host" },
      { "url" => "http://localhost:3030", "description" => "Localhost (default)" }
    ]
  }
end
