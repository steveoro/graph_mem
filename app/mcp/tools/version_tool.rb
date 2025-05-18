# frozen_string_literal: true

class VersionTool < ApplicationMCPTool
  description "Returns the current Graph-Memory backend version"

  def perform
    render(text: GraphMemoryBackend::VERSION.to_s, mime_type: "text/plain")
  end
end
