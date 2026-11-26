# frozen_string_literal: true

require "rails_helper"

# Dream State R1b: the dependency-like types list on Settings › Review policies.
RSpec.describe "Settings › Review policies › Dependency-like entity types", type: :request do
  def save(value)
    patch system_settings_path, params: { tab: "review_policies", settings: { "dependency_like_types" => value } }
  end

  before { sign_in_operator }

  it "shows the default with its help text" do
    get system_settings_path(tab: "review_policies")

    expect(response).to have_http_status(:ok)
    field = Nokogiri::HTML(response.body).at_css("[data-testid='field-dependency_like_types']")
    expect(field.at_css("input")["value"]).to eq("Framework, Gem, Tool")
    expect(field.text).to include("Dependency-like entity types", "Project depends_on")
  end

  it "saves the list normalized, with one audit row, and the next read uses it" do
    save(" Gem ,SynthPlugin,, gem ")

    expect(response).to redirect_to(system_settings_path(tab: "review_policies"))
    expect(AppSettings.dependency_like_types_list).to eq("Gem, SynthPlugin")
    expect(DependencyLikeTypes.current.match?("synthplugin")).to be(true)
    log = AuditLog.find_by!(auditable_type: "AppSettings")
    expect(log.changed_fields).to eq("dependency_like_types" => { "from" => "Framework, Gem, Tool", "to" => "Gem, SynthPlugin" })
  end

  it "refuses an entry naming Project with 422 and saves nothing" do
    save("Gem, Project")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Dependency-like entity types not saved: Project")
    expect(AppSettings.dependency_like_types_list).to eq("Framework, Gem, Tool")
  end

  it "accepts a blank list, which turns the R1b steps off" do
    save("")

    expect(AppSettings.dependency_like_types_list).to eq("")
    expect(DependencyLikeTypes.current).to be_empty
  end
end
