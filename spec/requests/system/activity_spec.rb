# frozen_string_literal: true

require "rails_helper"

# UI-7 S6: System › Activity, every change set newest first (50 a page), Undo only while undoable.
RSpec.describe "System › Activity", type: :request do
  def change_set(summary, **attributes)
    ChangeSet.create!({ uuid: SecureRandom.uuid, kind: "graph.write", actor: "agent:synth-client", summary: summary,
                        undo_strategy: "audit", undoable_until: 1.day.from_now }.merge(attributes))
  end

  it "answers 403 to a guest and sends a signed-out visitor to the sign-in page" do
    get system_activity_path
    expect(response).to redirect_to(operator_login_path)

    enable_guest!
    sign_in_guest
    get system_activity_path
    expect(response).to have_http_status(:forbidden)
  end

  context "as the operator" do
    before { sign_in_operator }

    it "lists change sets newest first, with Undo only for an undoable one" do
      old = change_set("wrote 2 observations to SynthWidget", created_at: 2.hours.ago, undoable_until: 1.hour.ago)
      undone = change_set("renamed Gadget Project", created_at: 1.hour.ago, undone_at: 10.minutes.ago)
      fresh = change_set("merged SynthWidget Twin into SynthWidget")

      get system_activity_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-testid^='activity-row-']").map { |row| row["data-testid"] })
        .to eq([ fresh, undone, old ].map { |set| "activity-row-#{set.uuid}" })
      expect(doc.at_css("[data-testid='activity-undo-#{fresh.uuid}']")).to be_present
      expect(doc.at_css("[data-testid='activity-undo-#{old.uuid}']")).to be_nil
      expect(doc.at_css("[data-testid='activity-row-#{undone.uuid}']").text).to include("undone")
      expect(doc.at_css("[data-testid='activity-row-#{fresh.uuid}'] form")["action"]).to eq(undo_change_path(fresh.uuid))
      expect(doc.at_css("[data-testid='activity-audit-log-link']")["href"]).to eq(system_audit_log_path)
    end

    it "shows the actor, the claim on a second line, and the kind in words" do
      mcp = change_set(nil, actor: "mcp:graph_write", actor_claim: "client=synth-client-a · <b>synth</b>")
      nameless = change_set(nil, kind: "review.apply", actor: nil)

      get system_activity_path

      doc = Nokogiri::HTML(response.body)
      row = doc.at_css("[data-testid='activity-row-#{mcp.uuid}']")
      expect(row.text).to include("Graph write", "graph.write", "mcp:graph_write")
      expect(row.at_css("[data-testid='activity-claim']").text).to eq("claimed: client=synth-client-a · <b>synth</b>")
      expect(row.at_css("b")).to be_nil
      expect(doc.at_css("[data-testid='activity-row-#{nameless.uuid}']").text).to include("Review apply", "unknown")
    end

    it "pages 50 change sets at a time" do
      ChangeSet.insert_all!(Array.new(51) do |index|
        { uuid: SecureRandom.uuid, kind: "graph.write", actor: "agent:synth-client", summary: "synthetic change #{index}",
          undo_strategy: "audit", created_at: index.minutes.ago, updated_at: Time.current }
      end)

      get system_activity_path
      expect(Nokogiri::HTML(response.body).css("[data-testid^='activity-row-']").size).to eq(50)

      get system_activity_path(page: 2)
      expect(Nokogiri::HTML(response.body).css("[data-testid^='activity-row-']").size).to eq(1)
    end
  end
end
