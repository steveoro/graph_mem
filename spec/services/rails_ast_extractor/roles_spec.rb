# frozen_string_literal: true

require "rails_helper"

# 1.74.0: the Rails role rules, on their own.
RSpec.describe RailsAstExtractor::Roles do
  it "gives a file's main constant its directory's role" do
    expect(described_class.dir_role("app/models/gadget/badge.rb", "Gadget::Badge", "Class")).to eq("Model")
    expect(described_class.dir_role("app/strategies/gadget/importers/badge.rb", "Gadget::Importers::Badge", "Class")).to eq("Strategy")
    expect(described_class.dir_role("app/controllers/gadget/widgets_controller.rb", "Gadget::WidgetsController", "Class")).to eq("Controller")
    expect(described_class.dir_role("app/commands/gadget/render_frame.rb", "Gadget::RenderFrame", "Class")).to eq("Command")
    expect(described_class.dir_role("app/api/gadget/v1/widgets.rb", "Gadget::V1::Widgets", "Class")).to eq("APIEndpoint")
  end

  it "matches acronym inflections by comparing underscored names" do
    expect(described_class.dir_role("app/services/gadget_db/api_client.rb", "GadgetDB::APIClient", "Class")).to eq("Service")
  end

  it "makes a module a namespace (Module) except in helpers, and a concerns-root module a Concern" do
    expect(described_class.dir_role("app/models/gadget.rb", "Gadget", "Module")).to eq("Module")
    expect(described_class.dir_role("app/helpers/gadget/widgets_helper.rb", "Gadget::WidgetsHelper", "Module")).to eq("Helper")
    expect(described_class.dir_role("app/models/concerns/framed.rb", "Framed", "Module")).to eq("Concern")
    expect(described_class.dir_role("app/controllers/concerns/gadget/paged.rb", "Gadget::Paged", "Module")).to eq("Concern")
  end

  it "gives no role to a constant the path doesn't name, to lib/ and to unknown dirs" do
    expect(described_class.dir_role("app/models/gadget/badge.rb", "Gadget::Badge::Error", "Class")).to be_nil
    expect(described_class.dir_role("lib/gadget/frame_buffer.rb", "Gadget::FrameBuffer", "Class")).to be_nil
    expect(described_class.dir_role("app/grids/gadget/widgets_grid.rb", "Gadget::WidgetsGrid", "Class")).to be_nil
    expect(described_class.dir_role("config/initializers/gadget.rb", "Gadget", "Module")).to be_nil
  end

  it "maps the Rails bases (with or without a leading ::) to roles" do
    expect(described_class.superclass_role("::ActiveRecord::Base")).to eq("Model")
    expect(described_class.superclass_role("ApplicationJob")).to eq("Job")
    expect(described_class.superclass_role("ActionController::API")).to eq("Controller")
    expect(described_class.superclass_role("Grape::API")).to eq("APIEndpoint")
    expect(described_class.superclass_role("StandardError")).to be_nil
  end

  it "matches a path with a digit segment, which the class name doesn't underscore back to (1.75.0)" do
    expect(described_class.main_constant?("app/models/goggles_db/best_50m_result.rb", "app/models", "GogglesDb::Best50mResult")).to be(true)
    expect(described_class.dir_role("app/models/goggles_db/best_50m_result.rb", "GogglesDb::Best50mResult", "Class")).to eq("Model")
    expect(described_class.main_constant?("app/models/goggles_db/best_50m_result.rb", "app/models", "GogglesDb::BestResult")).to be(false)
  end
end
