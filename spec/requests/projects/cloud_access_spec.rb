# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR2, step U: the Projects page "Cloud" column, the only place cloud_allowed is set.
RSpec.describe "Projects › Cloud access", type: :request do
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id) }

  def toggle(entity, allowed) = patch projects_cloud_access_path(entity), params: { allowed: allowed }

  context "as the operator" do
    before { sign_in_operator }

    it "shows the column, off by default, with the confirm and the note" do
      get projects_path

      cell = Nokogiri::HTML(response.body).at_css("[data-testid='project-cloud-#{project.id}']")
      expect(cell.text).to include("Off", "Allow")
      expect(cell.at_css("form")["data-turbo-confirm"]).to start_with("Allow this project's data, anonymized")
      expect(response.body).to include("No cloud provider is configured yet")
    end

    it "turns it on and off, each in a project.cloud_access change set with an audit row" do
      expect { toggle(project, "true") }.to change(ChangeSet, :count).by(1).and change { AuditLog.where(auditable: project).count }.by(1)
      expect(response).to redirect_to(projects_path)
      expect(flash[:notice]).to eq("Cloud access is on for Gadget Project. It has no completed scan yet, so its scans stay local.")
      expect(project.reload.cloud_allowed).to be(true)
      expect(ChangeSet.last).to have_attributes(kind: "project.cloud_access", summary: "allowed cloud access for 'Gadget Project'")
      expect(AuditLog.where(auditable: project).last.changed_fields).to include("cloud_allowed" => { "from" => false, "to" => true })

      toggle(project, "false")
      expect(project.reload.cloud_allowed).to be(false)
      expect(flash[:notice]).to eq("Cloud access is off for Gadget Project.")
    end

    it "records the folder of the project's last completed scan, shows it, and clears it when turned off" do
      { "completed" => "/path/to/gadget", "failed" => "/path/to/other" }.each do |status, root|
        OperationProgress.create!(operation_type: "project_scan", operation_id: SecureRandom.uuid, status: status,
                                  details: { "project_root" => root, "project_entity_id" => project.id })
      end

      get projects_path
      expect(Nokogiri::HTML(response.body).at_css("[data-testid='project-cloud-#{project.id}'] form")["data-turbo-confirm"])
        .to end_with("Cloud scans will be allowed only from /path/to/gadget.")
      toggle(project, "true")
      expect(project.reload.cloud_root).to eq("/path/to/gadget")
      expect(flash[:notice]).to end_with("Cloud scans only from /path/to/gadget.")
      get projects_path
      expect(response.body).to include("scans from /path/to/gadget")

      toggle(project, "false")
      expect(project.reload).to have_attributes(cloud_allowed: false, cloud_root: nil)
    end

    it "answers 404 for a member or an unknown id, and 422 for another value" do
      toggle(widget, "true")
      expect(response).to have_http_status(:not_found)
      toggle(MemoryEntity.maximum(:id) + 1, "true")
      expect(response).to have_http_status(:not_found)
      toggle(project, "yes")
      expect(response).to have_http_status(:unprocessable_content)
      expect(project.reload.cloud_allowed).to be(false)
    end
  end

  it "refuses a guest (403)" do
    enable_guest!
    sign_in_guest
    toggle(project, "true")

    expect(response).to have_http_status(:forbidden)
    expect(project.reload.cloud_allowed).to be(false)
  end
end
