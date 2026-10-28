# frozen_string_literal: true

require "rails_helper"

# Home (UI-2b, ui-dashboard-plan.md §2.2): operator only, status only, widgets in lazy Turbo
# Frames, and its only form is the quick search. Synthetic data only.
RSpec.describe "Home", type: :request do
  include ReviewHelper

  let(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }

  def section_doc(section)
    get home_section_path(section)
    expect(response).to have_http_status(:ok), section.to_s
    Nokogiri::HTML(response.body)
  end

  def pill(key, status)
    { key: key, label: key.to_s.humanize, status: status, value: "synthetic #{status}", href: "/#{key}" }
  end

  context "as the operator" do
    before { sign_in_operator }

    it "renders the quick search and one lazy frame per widget" do
      get root_path

      expect(response).to have_http_status(:ok)
      main = Nokogiri::HTML(response.body).at_css("main")
      expect(main.at_css("h1").text).to eq("Home")
      frames = main.css("turbo-frame")
      expect(frames.map { |frame| frame["id"] }).to eq(HomeSnapshot::SECTIONS.map { |section| "home-#{section}" })
      expect(frames.map { |frame| frame["src"] }).to eq(HomeSnapshot::SECTIONS.map { |section| home_section_path(section) })
      expect(frames.map { |frame| frame["loading"] }).to eq([ "eager" ] + ([ "lazy" ] * (HomeSnapshot::SECTIONS.size - 1)))
      sidebar = Nokogiri::HTML(response.body).at_css("nav.ui-sidebar")
      expect(sidebar.css("a[aria-current='page']").map { |link| link["data-testid"] }).to eq([ "nav-home" ])
    end

    it "has no form but the quick search, on the page or in any widget" do
      get root_path

      forms = Nokogiri::HTML(response.body).css("main form")
      expect(forms.size).to eq(1)
      expect(forms.first["action"]).to eq(search_path)
      expect(forms.first["method"]).to eq("get")
      expect(forms.first.css("input[name]").map { |input| input["name"] }).to eq([ "q" ])

      HomeSnapshot::SECTIONS.each do |section|
        expect(section_doc(section).css("form, button")).to be_empty, section.to_s
      end
    end

    it "colours the health strip green, amber and red from the snapshot, with the status in words" do
      allow(HomeSnapshot).to receive(:section).and_call_original
      allow(HomeSnapshot).to receive(:section).with(:health)
                                              .and_return([ pill(:database, :ok), pill(:backup, :warn), pill(:embeddings, :danger), pill(:guest, :neutral) ])

      pills = section_doc(:health).css("[data-testid^='home-pill-']")

      expect(pills.map { |link| [ link["data-testid"], link["class"], link["href"] ] }).to eq([
        [ "home-pill-database", "home-pill home-pill--ok", "/database" ],
        [ "home-pill-backup", "home-pill home-pill--warn", "/backup" ],
        [ "home-pill-embeddings", "home-pill home-pill--danger", "/embeddings" ],
        [ "home-pill-guest", "home-pill home-pill--neutral", "/guest" ]
      ])
      expect(pills.map { |link| link.at_css(".home-pill__status").text }).to eq(%w[OK Check Problem Info])
      expect(pills.map { |link| link["data-turbo-frame"] }).to all(eq("_top"))
    end

    it "builds the real strip with the embedding service unreachable" do
      pills = Dir.mktmpdir("home_backups") do |dir|
        AppSettings.backup_folder_path = dir # an empty backup folder, never the repo's db/backup
        section_doc(:health).css("[data-testid^='home-pill-']")
      end

      expect(pills.map { |link| link["data-testid"].delete_prefix("home-pill-") }).to eq(%w[database embeddings summaries jobs backup scans mcp guest])
      embeddings = pills.find { |link| link["data-testid"] == "home-pill-embeddings" }
      expect(embeddings["data-status"]).to eq("danger")
      expect(embeddings.text).to include("unreachable")
      mcp = pills.find { |link| link["data-testid"] == "home-pill-mcp" }
      expect(mcp["href"]).to eq(operator_settings_path(tab: "mcp_access"))
      expect(mcp.text).to include(GraphMem::OfficialMcp.access_policy.describe)
    end

    it "links each digest row to its group on /review" do
      allow(AppSettings).to receive(:review_number).and_call_original
      allow(AppSettings).to receive(:review_number).with(:review_attention_threshold).and_return(1)
      CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [
        { id: SecureRandom.uuid, kind: "relationship_proposal", from_entity_id: widget.id, to_entity_id: beta.id,
          relation_type: "depends_on", confidence_band: "high", score: 14 }
      ])
      group_key = MaintenanceReportRow.active.sole.group_key

      doc = section_doc(:digest)

      rows = doc.css("[data-testid='home-digest-row']")
      expect(rows.size).to eq(1)
      expect(rows.first.text).to include("Relationship proposal", "1 suggestion")
      anchor = review_group_dom_id(group_key)
      expect(rows.first.at_css("a[data-testid='home-digest-open']")["href"]).to eq(review_path(anchor: anchor))
      expect(doc.at_css("[data-testid='home-digest-state']").text).to include("1 group needs attention")

      get review_path
      expect(Nokogiri::HTML(response.body).at_css("##{anchor}")).to be_present
    end

    it "says inbox zero when nothing needs attention" do
      expect(section_doc(:digest).at_css("[data-testid='home-digest-state']").text).to include("Inbox zero ✓", "no policy run yet")
    end

    it "lists running and recent jobs, live-wired, and links to the controls" do
      running = OperationProgress.start!(operation_type: "garbage_collection", total_count: 4, phase: "orphans")
      OperationProgress.create!(operation_type: "project_scan", operation_id: SecureRandom.uuid, status: "failed",
                                total_count: 1, current_count: 0, percentage: 0, finished_at: 2.minutes.ago, error_message: "synthetic failure")

      doc = section_doc(:jobs)

      live = doc.at_css("[data-testid='home-job-running']")
      expect(live["data-controller"]).to eq("operation-progress")
      expect(live["data-operation-progress-operation-id-value"]).to eq(running.operation_id)
      expect(doc.at_css("[data-testid='home-job-recent']").text).to include("Project scan", "failed", "synthetic failure")
      expect(doc.css("a").map { |link| link["href"] }).to include(maintenance_path(anchor: "background-jobs"), "/operator/jobs")
    end

    it "lists the latest change sets, status only" do
      ChangeSet.create!(uuid: SecureRandom.uuid, kind: "graph.write", actor: "agent:synth-client", summary: "wrote 4 observations to SynthWidget",
                        undo_strategy: "audit", undoable_until: 1.day.from_now)

      doc = section_doc(:activity)

      row = doc.at_css("[data-testid='home-activity-row']")
      expect(row.text).to include("graph.write", "agent:synth-client: wrote 4 observations to SynthWidget", "undoable")
      expect(row["title"]).to include("undoable until")
      expect(doc.css("form, button")).to be_empty
      expect(doc.at_css("a")["href"]).to eq(operator_audit_logs_path)
    end

    it "shows the active MCP clients, compact" do
      AgentContext.create!(client_id: "synth-client", current_project: MemoryEntity.create!(name: "Alpha Service", entity_type: "Project"),
                           last_seen_at: 1.minute.ago, last_tool_name: "search")

      doc = section_doc(:clients)

      expect(doc.at_css("[data-testid='home-client-row']").text).to include("synth-client", "active", "Alpha Service")
      expect(doc.text).to include("1 active of 1")
      expect(doc.at_css("a")["href"]).to eq(maintenance_path(anchor: "mcp-clients"))
    end

    it "shows the graph counts and embedding coverage" do
      MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.")

      text = section_doc(:counts).at_css("[data-testid='home-counts']").text

      expect(text).to include("Entities", "Observations", "Relations", "Orphans", "Embedding coverage")
    end

    it "shows a broken widget as unavailable in its own frame, and the others as usual" do
      allow(HomeSnapshot).to receive(:section).and_call_original
      allow(HomeSnapshot).to receive(:section).with(:digest).and_raise(ActiveRecord::StatementInvalid, "synthetic failure")
      allow(Rails.error).to receive(:report)
      allow(Rails.logger).to receive(:error).and_call_original

      doc = section_doc(:digest)

      expect(doc.at_css("turbo-frame#home-digest [data-testid='home-unavailable-digest']").text).to include("Review digest: unavailable")
      expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::StatementInvalid), hash_including(handled: true))
      expect(Rails.logger).to have_received(:error).with("Home widget digest failed: ActiveRecord::StatementInvalid: synthetic failure")
      expect(section_doc(:health).at_css("[data-testid='home-health']")).to be_present
    end

    it "escapes markup in entity names and change-set summaries" do
      allow(AppSettings).to receive(:review_number).and_call_original
      allow(AppSettings).to receive(:review_number).with(:review_attention_threshold).and_return(1)
      marked = MemoryEntity.create!(name: "<b>Synth</b>Widget", entity_type: "Component")
      other = MemoryEntity.create!(name: "<b>Synth</b>Gadget", entity_type: "Component") # either may anchor the group
      CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [
        { id: SecureRandom.uuid, kind: "relationship_proposal", from_entity_id: marked.id, to_entity_id: other.id,
          relation_type: "depends_on", confidence_band: "high", score: 14 }
      ])
      ChangeSet.create!(uuid: SecureRandom.uuid, kind: "graph.write", actor: "agent:synth", summary: "<script>synth()</script> wrote 1 observation")

      digest_row = section_doc(:digest).at_css("[data-testid='home-digest-row']")
      activity_row = section_doc(:activity).at_css("[data-testid='home-activity-row']")

      expect(digest_row.at_css("b")).to be_nil
      expect(digest_row.text).to match(%r{<b>Synth</b>(Widget|Gadget)})
      expect(activity_row.at_css("script")).to be_nil
      expect(activity_row.text).to include("<script>synth()</script> wrote 1 observation")
    end

    it "answers 404 for an unknown widget" do
      get home_section_path("bogus")

      expect(response).to have_http_status(:not_found)
    end
  end

  context "as the guest" do
    before do
      enable_guest!
      sign_in_guest
    end

    it "sends Home to Search and refuses the widgets" do
      get root_path
      expect(response).to redirect_to(search_path)

      get home_section_path("health")
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "sends a signed-out visitor to the sign-in page" do
    get root_path
    expect(response).to redirect_to(operator_login_path)

    get home_section_path("health")
    expect(response).to redirect_to(operator_login_path)
  end

  describe "GET /graph" do
    before { sign_in_operator }

    it "renders the graph explorer with Stimulus hooks" do
      get graph_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="graph"', 'data-graph-target="container"')
    end
  end
end
