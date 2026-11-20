# frozen_string_literal: true

require "rails_helper"

# R1a: System › Background jobs › Relation types: the sweep's dry run and start, its reports, and
# the unmapped types page (map, accept, remove).
RSpec.describe "System › Background jobs › Relation types", type: :request do
  include ActiveJob::TestHelper

  let(:suffix) { SecureRandom.hex(3) }
  let(:service) { MemoryEntity.create!(name: "SynthService #{suffix}", entity_type: "Service") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component") }
  let(:gadget) { MemoryEntity.create!(name: "Alpha Service #{suffix}", entity_type: "Service") }
  let(:other) { MemoryEntity.create!(name: "SynthGadget #{suffix}", entity_type: "Component") }

  # A relation stored with a raw type (rows written before fold-on-write): the save callback would
  # canonicalize it, so the type is written with update_column.
  def stored_relation(from, to, stored_type)
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder_#{SecureRandom.hex(4)}")
    relation.update_column(:relation_type, stored_type)
    relation
  end

  def html = Nokogiri::HTML(response.body)

  def listed
    html.css("[data-testid='unmapped-relation-type']").to_h do |row|
      [ row["data-type"], row.at_css("[data-testid='unmapped-relation-type-count']").text.squish.delete(",").to_i ]
    end
  end

  def toast(kind) = html.at_css("[data-testid='toast-#{kind}']")&.text.to_s.squish

  around do |example|
    RelationTypeMapping.reset_canonicalize_cache!
    example.run
  ensure
    RelationTypeMapping.reset_canonicalize_cache!
  end

  before { sign_in_operator }

  describe "GET /system/jobs/relation_types" do
    it "lists each unmapped type once with its total, case and spelling variants together, by count then name" do
      stored_relation(service, widget, "Synth Link Kind")
      stored_relation(widget, gadget, "synth link kind")
      stored_relation(gadget, service, "synth-link-kind")
      stored_relation(service, gadget, "synth_beta_kind")
      stored_relation(widget, service, "synth_alpha_kind")
      stored_relation(gadget, widget, "depends_on")  # canonical
      stored_relation(other, widget, "Requires") # a code-vocabulary variant
      stored_relation(other, service, "synth_mapped_kind")
      RelationTypeMapping.create!(variant: "synth_mapped_kind", canonical_type: "relates_to")
      stored_relation(other, gadget, "Synth Known Kind")
      RelationTypeMapping.create!(variant: "synth_known_kind", canonical_type: "synth_known_kind") # accepted

      get system_relation_types_path

      expect(response).to have_http_status(:ok)
      expect(listed.to_a).to eq([ [ "synth_link_kind", 3 ], [ "synth_alpha_kind", 1 ], [ "synth_beta_kind", 1 ] ])
      row = html.at_css("[data-testid='unmapped-relation-type'][data-type='synth_link_kind']")
      expect(row.text).to include("stored as:", "Synth Link Kind", "synth link kind", "synth-link-kind")
    end

    it "shows up to two example edges, oldest first, linked to the entities in Explore" do
      first = stored_relation(service, widget, "synth_links_to")
      stored_relation(widget, gadget, "Synth Links To")
      stored_relation(gadget, service, "synth_links_to")

      get system_relation_types_path

      examples = html.css("[data-type='synth_links_to'] [data-testid='unmapped-relation-type-example']")
      expect(examples.map { |li| li.text.squish })
        .to eq([ "#{service.name} —synth_links_to→ #{widget.name}", "#{widget.name} —Synth Links To→ #{gadget.name}" ])
      expect(examples.first.css("a").map { |a| a["href"] })
        .to eq([ explore_path(entity_id: first.from_entity_id), explore_path(entity_id: first.to_entity_id) ])
    end

    it "filters by a case-insensitive part of the type or a spelling" do
      stored_relation(service, widget, "synth_links_to")
      stored_relation(widget, gadget, "synth_owns")

      get system_relation_types_path, params: { q: "LINKS" }

      expect(listed.keys).to eq([ "synth_links_to" ])
      expect(html.at_css("#relation_types_filter")["value"]).to eq("LINKS")
      expect(html.at_css("label[for='relation_types_filter']")).to be_present
    end

    it "offers a labelled select of the canonical types and an Accept button per type" do
      stored_relation(service, widget, "synth_links_to")

      get system_relation_types_path

      row = html.at_css("[data-type='synth_links_to']")
      select = row.at_css("select[name='canonical_type']")
      expect(select.css("option").map { |option| option["value"] }).to eq(GraphVocabulary::RELATION_TYPES.sort)
      expect(row.at_css("label[for='#{select['id']}']").text).to eq("Canonical type for synth_links_to")
      expect(row.at_css("[data-testid='btn-accept-relation-type']")["aria-label"]).to eq("Accept synth_links_to as a known type")
    end

    it "lists the mapping rows with their kind and a Remove that says no relation changes" do
      RelationTypeMapping.create!(variant: "synth_mapped_kind", canonical_type: "relates_to")
      RelationTypeMapping.create!(variant: "synth_known_kind", canonical_type: "synth_known_kind")
      RelationTypeMapping.create!(variant: "part_of", canonical_type: "part_of")

      get system_relation_types_path

      rows = html.css("[data-testid='relation-type-mapping']").to_h { |row| [ row["data-variant"], row["data-kind"] ] }
      expect(rows).to eq("part_of" => "canonical", "synth_known_kind" => "accepted", "synth_mapped_kind" => "mapped")
      remove = html.at_css("[data-variant='synth_mapped_kind'] [data-testid='btn-remove-relation-type-mapping']")
      expect(remove["data-turbo-confirm"]).to include("No relation changes")
      expect(html.at_css("[data-testid='relation-type-mappings']").text).to include("Removing a row changes no relation")
    end

    it "says so when nothing is unmapped" do
      stored_relation(service, widget, "depends_on")

      get system_relation_types_path

      expect(html.at_css("[data-testid='unmapped-relation-types-empty']").text.squish).to eq("No unmapped relation type.")
    end
  end

  describe "POST /system/jobs/relation_types/map" do
    it "maps the type, says how many relations the next sweep retypes, and links to the sweep; the sweep then retypes them" do
      first = stored_relation(service, widget, "Synth Links To")
      second = stored_relation(widget, gadget, "synth_links_to")

      post system_map_relation_type_path, params: { type: "Synth Links To", canonical_type: "depends_on" }

      expect(response).to redirect_to(system_relation_types_path)
      expect(RelationTypeMapping.find_by!(variant: "synth_links_to").canonical_type).to eq("depends_on")
      expect(first.reload.relation_type).to eq("Synth Links To") # nothing retyped inline
      follow_redirect!
      expect(toast(:notice)).to include("synth_links_to now maps to depends_on: the next sweep retypes its 2 relations.")
      expect(html.at_css("[data-testid='toast-link']")["href"]).to eq(system_relation_types_sweep_path)
      expect(listed).to be_empty

      RelationTypeSweep.call

      expect([ first.reload.relation_type, second.reload.relation_type ]).to eq(%w[depends_on depends_on])
    end

    it "says the sweep queues part_of candidates for review instead of retyping them" do
      stored_relation(service, widget, "synth_inside")

      post system_map_relation_type_path, params: { type: "synth_inside", canonical_type: "part_of" }

      follow_redirect!
      expect(toast(:notice)).to include("synth_inside now maps to part_of: the next sweep queues its 1 relation for review")
    end

    it "keeps the filter when it redirects" do
      stored_relation(service, widget, "synth_links_to")

      post system_map_relation_type_path, params: { type: "synth_links_to", canonical_type: "depends_on", q: "synth" }

      expect(response).to redirect_to(system_relation_types_path(q: "synth"))
    end

    {
      "a target outside the vocabulary" => [ { type: "synth_links_to", canonical_type: "synth_other" }, "synth_other isn't a canonical relation type" ],
      "a canonical type" => [ { type: "Depends On", canonical_type: "relates_to" }, "depends_on is a canonical type already" ],
      "a code-vocabulary variant" => [ { type: "requires", canonical_type: "relates_to" }, "requires is already mapped or accepted" ],
      "a blank type" => [ { type: " ", canonical_type: "relates_to" }, "No type was given" ]
    }.each do |label, (params, message)|
      it "refuses #{label}" do
        stored_relation(service, widget, "synth_links_to")

        expect { post system_map_relation_type_path, params: params }.not_to change(RelationTypeMapping, :count)

        follow_redirect!
        expect(toast(:alert)).to include(message)
      end
    end

    it "refuses a type already mapped or accepted" do
      RelationTypeMapping.create!(variant: "synth_links_to", canonical_type: "synth_links_to")

      post system_map_relation_type_path, params: { type: "Synth-Links-To", canonical_type: "depends_on" }

      expect(RelationTypeMapping.find_by!(variant: "synth_links_to").canonical_type).to eq("synth_links_to")
      follow_redirect!
      expect(toast(:alert)).to include("Remove its mapping first")
    end
  end

  describe "POST /system/jobs/relation_types/accept" do
    it "stores a self-mapping; the type leaves the list, the sweep folds its spellings, and a second sweep finds nothing" do
      spaced = stored_relation(service, widget, "Synth Links To")
      upper = stored_relation(widget, gadget, "SYNTH_LINKS_TO")
      folded = stored_relation(gadget, service, "synth_links_to")

      post system_accept_relation_type_path, params: { type: "Synth Links To" }

      expect(RelationTypeMapping.find_by!(variant: "synth_links_to").canonical_type).to eq("synth_links_to")
      follow_redirect!
      expect(toast(:notice)).to include("synth_links_to is accepted as a known type (3 relations)")
      expect(listed).to be_empty
      expect(RelationTypeSweep.target_type("Synth Links To")).to eq("synth_links_to")

      summary = RelationTypeSweep.call

      expect(summary[:counts]).to include("retyped" => 1, "case_only" => 1, "unchanged" => 1)
      expect([ spaced, upper, folded ].map { |relation| relation.reload.relation_type }).to all(eq("synth_links_to"))
      expect(RelationTypeSweep.call(dry_run: true)[:counts]).to include("scanned" => 3, "unchanged" => 3)
    end

    it "refuses a canonical type" do
      expect { post system_accept_relation_type_path, params: { type: "relates_to" } }.not_to change(RelationTypeMapping, :count)

      follow_redirect!
      expect(toast(:alert)).to include("relates_to is a canonical type already")
    end
  end

  describe "DELETE /system/jobs/relation_types/mappings/:id" do
    it "removes the row, changes no relation, and the type is listed again" do
      relation = stored_relation(service, widget, "synth_links_to")
      post system_accept_relation_type_path, params: { type: "synth_links_to" }
      mapping = RelationTypeMapping.find_by!(variant: "synth_links_to")

      delete system_relation_type_mapping_path(mapping)

      expect(RelationTypeMapping.exists?(mapping.id)).to be(false)
      expect(relation.reload.relation_type).to eq("synth_links_to")
      follow_redirect!
      expect(toast(:notice)).to include("The mapping of synth_links_to is removed. No relation changed.")
      expect(listed).to eq("synth_links_to" => 1)
    end

    it "says the code vocabulary still maps a type whose row it removes (an older install's seed)" do
      mapping = RelationTypeMapping.create!(variant: "imports", canonical_type: "depends_on")

      delete system_relation_type_mapping_path(mapping)

      follow_redirect!
      expect(toast(:notice)).to include("The mapping of imports is removed, but the code vocabulary still maps it to depends_on, " \
                                        "so it stays mapped. No relation changed.")
      expect(MemoryRelation.mapped_relation_type("imports")).to eq("depends_on")
    end

    it "says so for a mapping that no longer exists" do
      delete system_relation_type_mapping_path(id: 0)

      follow_redirect!
      expect(toast(:alert)).to include("That mapping no longer exists")
    end
  end

  describe "GET /system/jobs/relation_types/sweep (the dry run)" do
    it "shows what a sweep would do, writes nothing, and offers the confirm button" do
      variant = stored_relation(service, widget, "requires")
      stored_relation(widget, gadget, "Depends_On")
      stored_relation(gadget, service, "depends_on")

      expect { get system_relation_types_sweep_path }.not_to change(MaintenanceReport, :count)

      expect(response).to have_http_status(:ok)
      counts = %w[scanned unchanged retyped case_only merged queued].to_h do |key|
        [ key, html.at_css("[data-testid='dry-run-#{key}'] .system-stat__value").text.to_i ]
      end
      expect(counts).to eq("scanned" => 3, "unchanged" => 1, "retyped" => 1, "case_only" => 1, "merged" => 0, "queued" => 0)
      expect(variant.reload.relation_type).to eq("requires")
      button = html.at_css("form[action='#{system_relation_types_sweep_path}'] [data-testid='btn-relation-types-confirm']")
      expect(button["data-turbo-confirm"]).to be_present
    end

    it "offers nothing to run when nothing would change" do
      stored_relation(service, widget, "depends_on")

      get system_relation_types_sweep_path

      expect(html.at_css("[data-testid='relation-types-nothing']")).to be_present
      expect(html.at_css("[data-testid='btn-relation-types-confirm']")).to be_nil
    end

    it "says a sweep is running instead of offering the button" do
      stored_relation(service, widget, "requires")
      OperationProgress.start!(operation_type: "relation_type_sweep", total_count: 1)

      get system_relation_types_sweep_path

      expect(html.at_css("[data-testid='relation-types-busy']").text).to include("already queued or running")
      expect(html.at_css("[data-testid='btn-relation-types-confirm']")).to be_nil
    end
  end

  describe "POST /system/jobs/relation_types/sweep" do
    it "queues the sweep as the operator and returns to Background jobs" do
      expect { post system_relation_types_sweep_path }
        .to have_enqueued_job(RelationTypeSweepJob).with(actor: a_string_starting_with("operator:#{OperatorAuthHelpers::TEST_OPERATOR_USERNAME}@"))

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(toast(:notice)).to include("Relation type sweep queued")
    end

    it "refuses while a sweep is running" do
      OperationProgress.start!(operation_type: "relation_type_sweep", total_count: 1)

      expect { post system_relation_types_sweep_path }.not_to have_enqueued_job(RelationTypeSweepJob)

      expect(response).to redirect_to(system_relation_types_sweep_path)
      follow_redirect!
      expect(toast(:alert)).to include("already queued or running")
    end

    it "no longer counts a running progress row nobody has updated for a while" do
      OperationProgress.start!(operation_type: "relation_type_sweep", total_count: 1)
                       .update_columns(updated_at: (RelationTypeSweepJob::STALE_AFTER + 1.minute).ago)

      expect { post system_relation_types_sweep_path }.to have_enqueued_job(RelationTypeSweepJob)
    end

    it "refuses while a dream-state run is running (its first phase is the same sweep)" do
      CompactionRun.create!(status: "running", phase: "relation_types", stats: {})

      expect { post system_relation_types_sweep_path }.not_to have_enqueued_job(RelationTypeSweepJob)

      follow_redirect!
      expect(toast(:alert)).to include("A dream-state run is in progress")
    end
  end

  describe "GET /system/jobs/relation_types/reports/:id" do
    it "shows the counts, who ran it, and the change list, paginated, with entity and review links" do
      stub_const("System::RelationTypesController::CHANGES_PER_PAGE", 2)
      twin = MemoryRelation.create!(from_entity: service, to_entity: widget, relation_type: "depends_on")
      merged = stored_relation(service, widget, "requires")
      queued = stored_relation(widget, gadget, "child_of")
      stored_relation(gadget, service, "invokes")
      report_id = RelationTypeSweep.call(actor: "operator:synth@127.0.0.1", source: "operator")[:report_id]

      get system_relation_types_report_path(report_id)

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-testid='relation-types-report-meta']").text).to include("operator:synth@127.0.0.1", "(operator)")
      rows = html.css("[data-testid='relation-types-change']")
      expect(rows.size).to eq(2)
      expect(rows.first.text.squish).to include("##{merged.id}", "Merged", "requires → depends_on", service.name, widget.name, "##{twin.id}")
      expect(rows.first.css("a").map { |a| a["href"] }).to include(explore_path(entity_id: service.id))
      row_uuid = MaintenanceReportRow.find_by!(kind: "relation_retype").row_uuid
      expect(rows.last.text.squish).to include("##{queued.id}", "Queued for review", "child_of → part_of")
      expect(rows.last.at_css("a[href='#{review_row_path(row_uuid)}']")).to be_present
      expect(html.at_css(".system-pagination a[href*='page=2']")).to be_present

      get system_relation_types_report_path(report_id, page: 2)
      expect(html.css("[data-testid='relation-types-change']").map { |row| row.text }).to contain_exactly(include("invokes → calls"))
    end

    it "notes the changes the report didn't keep" do
      report = MaintenanceReport.create!(report_type: "relation_type_sweep",
                                         data: { "counts" => { "scanned" => 5 }, "changes" => [], "changes_omitted" => 3 })

      get system_relation_types_report_path(report)

      expect(html.at_css("[data-testid='relation-types-report-omitted']").text)
        .to include("3 more changes aren't listed", "their audit rows are in the run's change sets")
      expect(html.at_css("[data-testid='relation-types-report-activity']")["href"]).to eq(system_activity_path)
    end

    it "is a 404 for another report type" do
      report = MaintenanceReport.create!(report_type: "orphans", data: { count: 0 })

      get system_relation_types_report_path(report)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the Relation types card on Background jobs" do
    def card = html.at_css("[data-testid='relation-types-card']")

    it "shows the unmapped count with a link to the page, and the sweep button" do
      stored_relation(service, widget, "synth_links_to")
      stored_relation(widget, gadget, "synth_owns")

      get system_jobs_path

      expect(card.at_css("[data-testid='relation-types-unmapped']").text).to include("2 stored types are neither canonical nor mapped")
      expect(card.at_css("[data-testid='relation-types-unmapped-link']")["href"]).to eq(system_relation_types_path)
      sweep = card.at_css("[data-testid='btn-relation-types-sweep']")
      expect(sweep["href"]).to eq(system_relation_types_sweep_path)
      expect(sweep["data-turbo-prefetch"]).to eq("false")
      expect(card.at_css("[data-testid='relation-types-last-run']").text).to include("No sweep has run yet")
    end

    it "shows the last report's counts, when and who, and links to its changes" do
      stored_relation(service, widget, "requires")
      report_id = RelationTypeSweep.call(actor: "operator:synth@127.0.0.1", source: "operator")[:report_id]

      get system_jobs_path

      expect(card.at_css("[data-testid='relation-types-last-run']").text).to include("Last sweep", "operator:synth@127.0.0.1")
      expect(card.at_css(".system-stats").text.squish).to match(/1\s*Retyped/)
      link = card.at_css("[data-testid='relation-types-report-link']")
      expect(link["href"]).to eq(system_relation_types_report_path(report_id))
      expect(link.text.squish).to eq("View the changes (1)")
    end

    it "shows the running sweep's bar and flags the cards active" do
      OperationProgress.start!(operation_type: "relation_type_sweep", total_count: 400, phase: "sweeping").update_progress!(current: 200)

      get system_jobs_cards_path

      expect(card.at_css("[data-testid='relation-types-progress']").text.squish).to eq("Sweeping: 200 of 400 (50%)")
      expect(html.at_css("[data-live-refresh-target='state']")["data-active"]).to eq("true")
    end

    it "shows a failed sweep's error" do
      OperationProgress.start!(operation_type: "relation_type_sweep", total_count: 1).fail!(StandardError.new("synth failure"))

      get system_jobs_path

      expect(card.at_css("[data-testid='relation-types-error']").text).to include("synth failure")
    end
  end

  describe "access" do
    let(:mapping) { RelationTypeMapping.create!(variant: "synth_links_to", canonical_type: "depends_on") }
    let(:report) { MaintenanceReport.create!(report_type: "relation_type_sweep", data: { "counts" => {}, "changes" => [] }) }

    def requests
      {
        "GET index" => [ :get, system_relation_types_path, {} ],
        "GET sweep" => [ :get, system_relation_types_sweep_path, {} ],
        "POST sweep" => [ :post, system_relation_types_sweep_path, {} ],
        "GET report" => [ :get, system_relation_types_report_path(report), {} ],
        "POST map" => [ :post, system_map_relation_type_path, { type: "synth_owns", canonical_type: "depends_on" } ],
        "POST accept" => [ :post, system_accept_relation_type_path, { type: "synth_owns" } ],
        "DELETE mapping" => [ :delete, system_relation_type_mapping_path(mapping), {} ]
      }
    end

    def state = [ RelationTypeMapping.pluck(:variant, :canonical_type).sort, enqueued_jobs.size ]

    it "answers a guest with 403 everywhere and changes nothing" do
      before_state = (mapping && report && state)
      enable_guest!
      sign_in_guest

      requests.each do |label, (verb, path, params)|
        send(verb, path, params: params)
        expect(response).to have_http_status(:forbidden), label
      end
      expect(state).to eq(before_state)
    end

    it "sends a signed-out visitor to sign in and changes nothing" do
      before_state = (mapping && report && state)
      reset!

      requests.each do |label, (verb, path, params)|
        send(verb, path, params: params)
        expect(response).to redirect_to(operator_login_path), label
      end
      expect(state).to eq(before_state)
    end

    it "refuses every write without a CSRF token (422) and changes nothing" do
      before_state = (mapping && report && state)
      ActionController::Base.allow_forgery_protection = true

      requests.select { |_label, (verb, _path, _params)| verb != :get }.each do |label, (verb, path, params)|
        send(verb, path, params: params)
        expect(response).to have_http_status(:unprocessable_content), label
      end
      expect(state).to eq(before_state)
    ensure
      ActionController::Base.allow_forgery_protection = false
    end
  end
end
