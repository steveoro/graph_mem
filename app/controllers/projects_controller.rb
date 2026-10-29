# frozen_string_literal: true

# Projects & Data's landing page (UI-6 P2): every Project root with its last scan, last import
# and pending scan-review groups. Operator only (Projects::BaseController).
class ProjectsController < Projects::BaseController
  def index
    @overview = ProjectsOverview.new(page: params[:page])
    @rows = @overview.rows
  end
end
