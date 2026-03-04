class PagesController < ApplicationController
  def home
    @vector_available = EmbeddingService.vector_enabled?
  end
end
