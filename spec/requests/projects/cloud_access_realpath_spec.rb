# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step S: turning Cloud on records the scan folder's realpath, and the confirm shows it.
RSpec.describe "Projects › Cloud access records the realpath", type: :request do
  around do |example|
    Dir.mktmpdir("cloud_access_realpath") do |dir|
      @tmp = File.realpath(dir)
      example.run
    end
  end

  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let(:real) { File.join(@tmp, "gadget").tap { |path| Dir.mkdir(path) } }
  let(:link) { File.join(@tmp, "gadget-link").tap { |path| File.symlink(real, path) } }

  before do
    sign_in_operator
    OperationProgress.create!(operation_type: "project_scan", operation_id: SecureRandom.uuid, status: "completed",
                              details: { "project_root" => link, "project_entity_id" => project.id })
  end

  it "shows and stores the realpath of a scan made through a symlink, and the gate allows it" do
    get projects_path
    form = Nokogiri::HTML(response.body).at_css("[data-testid='project-cloud-#{project.id}'] form")
    expect(form["data-turbo-confirm"]).to end_with("Cloud scans will be allowed only from #{real}.")

    patch projects_cloud_access_path(project), params: { allowed: "true", root: real }

    expect(project.reload).to have_attributes(cloud_allowed: true, cloud_root: real)
    expect(Llm::CloudGate.allowed?(Llm::Scope.for_scan(project_root: link, project_name: "Gadget Project"))).to be(true)
  end

  it "changes nothing when the confirm showed the symlink rather than the realpath" do
    patch projects_cloud_access_path(project), params: { allowed: "true", root: link }

    expect(flash[:alert]).to start_with("Cloud access for Gadget Project was not changed")
    expect(project.reload).to have_attributes(cloud_allowed: false, cloud_root: nil)
  end
end
