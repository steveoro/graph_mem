# frozen_string_literal: true

require "rails_helper"

# 1.96.1 (review guidance, item 1): every Review & Fix action says what it does. The detail card, the
# kind cards' own buttons and the confirm cards, the group confirm cards included (their writes have
# their own caption), show a caption under each button, tied to it by aria-describedby. The list rows
# and the group cards carry the same text as a title only, so the lists stay compact. Every .ui-btn
# of those cards is checked, so a new button needs one.
RSpec.describe "Review & Fix › action captions", type: :request do
  let!(:project) { fs_project!("SynthApp") }
  let!(:widget) { fs_member!(project, "SynthWidget") }
  let!(:gadget) { fs_member!(project, "SynthGadget") }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html" } }

  before { sign_in_operator }

  # Every kind the classifier names, and the one the applier knows besides.
  let(:all_kinds) do
    classifier = ReviewRowClassifier
    (classifier::DESTRUCTIVE_KINDS + classifier::SAFE_BULK_KINDS + classifier::INFORMATIONAL_KINDS + classifier::CHOICE_KINDS +
     classifier::ERROR_KINDS + classifier::SCAN_KINDS + classifier::IMPACT.keys + classifier::CONFIDENCE.keys +
     classifier::RUN_CAPS.keys + [ "dismiss_compaction_review" ]).uniq
  end

  def seed(item)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item.merge(id: SecureRandom.uuid) ]).sole
  end

  def global(name, type = "Component") = MemoryEntity.create!(name: name, entity_type: type)

  # @return [Hash{String => MaintenanceReportRow}] one pending row per kind (relation_retype: each operation, and the choice)
  def seed_every_kind
    loose = global("SynthLoose")
    observation = fs_observe!(widget, "SynthWidget renders with the canvas backend.")
    other_edge = MemoryRelation.create!(from_entity: widget, to_entity: loose, relation_type: "depends_on")
    rows = {
      "relationship_proposal" => seed(kind: "relationship_proposal", from_entity_id: gadget.id, to_entity_id: loose.id,
                                      relation_type: "depends_on", confidence_band: "high", score: 14),
      "entity_merge" => seed(kind: "entity_merge", entity_a: { entity_id: loose.id, name: loose.name },
                             entity_b: { entity_id: global("SynthLooseTwin").id, name: "SynthLooseTwin" }, cosine_distance: 0.05),
      "orphan_parent" => seed(kind: "orphan_parent", entity_id: global("synth-orphan-task", "Task").id, entity_name: "synth-orphan-task",
                              entity_type: "Task", suggested_parents: [ { project_id: project.id, project_name: project.name, score: 10 } ]),
      "stale_memory" => seed(kind: "stale_memory", entity_id: widget.id, entity_name: widget.name, signal: "valid_until_elapsed",
                             observation_ids: [ observation.id ], reason: "synthetic"),
      "delete_entity" => seed(kind: "delete_entity", entity_id: global("SynthDoomed").id, entity_name: "SynthDoomed", reason: "synthetic"),
      "delete_relation" => seed(kind: "delete_relation", relation_id: other_edge.id, reason: "synthetic"),
      "delete_observation" => seed(kind: "delete_observation", observation_id: observation.id, reason: "synthetic"),
      "reparent_entity" => seed(kind: "reparent_entity", entity_id: global("SynthDrifter").id, parent_id: project.id, reason: "synthetic"),
      "move_observation" => seed(kind: "move_observation", observation_id: observation.id, target_entity_id: gadget.id, reason: "synthetic"),
      "relation_integrity" => seed(kind: "relation_integrity", issue_kind: "same_direction",
                                   payload: { kind: "same_direction", keep_id: widget_part_of.id, delete_ids: [ other_edge.id ] }),
      "dismiss_compaction_review" => seed(kind: "dismiss_compaction_review", review_item_id: "synth-item"),
      "entity_error" => seed(kind: "entity_error", entity_id: loose.id, phase: "embedding", error: "synthetic"),
      "embedding_backfill_failed" => seed(kind: "embedding_backfill_failed", entity_id: loose.id, error: "synthetic"),
      "lifecycle_corruption" => lifecycle_row,
      "contradiction" => contradiction_row,
      "fact_supersede" => fact_supersede_row,
      "relation_review" => relation_review_row
    }
    rows.merge(relation_retype_rows)
  end

  def widget_part_of = MemoryRelation.find_by!(from_entity_id: widget.id, relation_type: "part_of")

  def lifecycle_row
    broken = fs_observe!(widget, "SynthWidget caches frames.").tap { |row| row.update_columns(obsoleted_at: 1.day.ago) }
    seed(kind: "lifecycle_corruption", observation_id: broken.id, entity_id: widget.id,
         issue: CompactionReviewApplier::LifecycleCorruption::ACTIVE_WITH_OBSOLETED_AT)
  end

  def contradiction_row
    sides = [ "SynthWidget is fast.", "SynthWidget is not fast." ].map { |content| fs_observe!(widget, content) }
    seed(ContradictionDetector.review_item(ContradictionDetector::Result.new(observation_id_1: sides.first.id, observation_id_2: sides.last.id,
                                                                              distance: 0.1, confidence: 0.9)))
  end

  def fact_supersede_row
    fact = fs_fact!(project, "SynthApp renders with the WebGL backend.")
    old = fs_observe!(widget, "SynthWidget renders with the SVG backend.")
    seed("kind" => "fact_supersede", "fact_observation_id" => fact.id, "observation_id" => old.id, "verdict" => "superseded",
         "confidence" => 0.7, "reason" => "synthetic", "replacement" => "SynthWidget renders with the WebGL backend.",
         "signals" => { "scoped" => true }, "content" => old.content, "fact_content" => fact.content, "entity_id" => widget.id,
         "entity_name" => widget.name, "project_id" => project.id, "project_name" => project.name)
  end

  def relation_review_row
    old_lib = global("SynthOldLib", "Gem")
    edge = MemoryRelation.create!(from_entity: project, to_entity: old_lib, relation_type: "depends_on")
    fact = fs_observe!(project, "SynthApp migrated away from SynthOldLib in 2.0.")
    seed(CompactionReviewApplier::RelationReview.item(MemoryRelation.includes(:from_entity, :to_entity).find(edge.id), fact))
  end

  # retype (an orphan's child_of a Project), the choice (a member's variant towards another member), swap and add.
  def relation_retype_rows
    stray = global("SynthStray")
    MemoryRelation.create!(from_entity: stray, to_entity: project, relation_type: "synth_placeholder").update_column(:relation_type, "child_of")
    MemoryRelation.create!(from_entity: widget, to_entity: gadget, relation_type: "synth_placeholder").update_column(:relation_type, "Is Part Of")
    RelationTypeSweep.call
    retypes = MaintenanceReportRow.where(kind: "relation_retype").index_by { |row| row.payload["from_entity_id"].to_i }
    library = fs_member!(project, "SynthLib", "Gem")
    part_of = MemoryRelation.find_by!(from_entity_id: library.id, relation_type: "part_of")
    names = { library.id => library.name, project.id => project.name }
    swap = CompactionReviewApplier::RelationRetypeDependency.swap_item(part_of, names, evidence: { entity_type: "Gem", facts: [] })
    add = CompactionReviewApplier::RelationRetypeDependency.add_item(project, global("SynthTool", "Tool"), evidence: { entity_type: "Tool" })
    { "relation_retype (retype)" => retypes.fetch(stray.id), "relation_retype (choice)" => retypes.fetch(widget.id),
      "relation_retype (swap)" => seed(swap.except(:id)), "relation_retype (add)" => seed(add.except(:id)) }
  end

  # @return [Array<Array(String, String)>] each action button of every card with that testid, [label,
  #   caption]; fails on a button without a caption
  def captions(testid, name)
    cards = Nokogiri::HTML5(response.body).css("[data-testid='#{testid}']")
    expect(cards).to be_present, "#{name}: no #{testid}"
    cards.flat_map do |card|
      card.css("a.ui-btn, button.ui-btn, input.ui-btn").map do |button|
        label = (button.text.presence || button["value"]).to_s.squish
        caption = button["aria-describedby"] && card.at_css("[id='#{button['aria-describedby']}']")
        expect(caption).to be_present, "#{name}: '#{label}' has no caption"
        expect(caption.at_css(".translation_missing")).to be_nil, "#{name}: '#{label}' has a missing caption"
        expect(caption.text.squish).to be_present
        [ label, caption.text.squish ]
      end
    end
  end

  # The grouped lists stay compact: each group card action carries its caption as a title.
  def titles(testid, name)
    cards = Nokogiri::HTML5(response.body).css("[data-testid='#{testid}']")
    expect(cards).to be_present, "#{name}: no #{testid}"
    cards.flat_map do |card|
      card.css("a.ui-btn, button.ui-btn, input.ui-btn").map do |button|
        label = (button.text.presence || button["value"]).to_s.squish
        expect(button["title"]).to be_present, "#{name}: '#{label}' has no title"
        expect(button["title"]).not_to include("translation_missing"), "#{name}: '#{label}' has a missing title"
        [ label, button["title"] ]
      end
    end
  end

  it "has a row for every kind the classifier names" do
    expect(seed_every_kind.values.map(&:kind).uniq).to match_array(all_kinds)
  end

  it "captions every action of the detail card and the confirm card, for every kind" do
    seed_every_kind.each do |name, row|
      get review_row_path(row.row_uuid)
      labels = captions("review-detail-card", name).map(&:first)
      expect(labels).to include("Snooze 30 days"), name
      expect(labels & [ "Dismiss", "Both are right" ]).to be_present, name

      Nokogiri::HTML5(response.body).css("[data-testid='review-detail-card'] a.ui-btn").each do |link|
        next unless link["href"].include?("/preview")

        get link["href"]
        expect(captions("review-preview-card", "#{name} › #{link.text.squish}").map(&:first)).to include("Cancel")
      end
    end
  end

  it "gives every list row action its caption as a title" do
    seed_every_kind.each do |name, row|
      get review_group_path(key: row.group_key)
      buttons = Nokogiri::HTML5(response.body).css("##{ActionView::RecordIdentifier.dom_id(row)} .review-row__actions .ui-btn")

      expect(buttons.size).to be >= 2, name
      buttons.each do |button|
        expect(button["title"]).to be_present, "#{name}: '#{button.text.squish}' has no title"
        expect(button["title"]).not_to include("translation_missing"), "#{name}: '#{button.text.squish}' has a missing title"
      end
    end
  end

  it "says what Dismiss, Snooze, Apply and Cancel do, and Apply now on a safe kind's list row" do
    rows = seed_every_kind
    get review_row_path(rows.fetch("relationship_proposal").row_uuid)
    expect(captions("review-detail-card", "proposal").to_h).to include(
      "Apply…" => "Opens a confirm card with what applying changes; nothing is written yet.",
      "Dismiss" => "Not right: nothing changes, and this suggestion isn't made again (Restore brings it back).",
      "Snooze 30 days" => "Not now: hidden for 30 days, then back in the queue at the next policy run.",
      "Save" => "Keeps your edits on the suggestion; nothing is applied yet."
    )
    get review_row_preview_path(rows.fetch("relationship_proposal").row_uuid)
    expect(captions("review-preview-card", "proposal").to_h).to eq(
      "Apply" => "Writes the changes listed above; the undo line above says whether Undo can revert them.",
      "Cancel" => "Back to the suggestion; nothing is written."
    )
    get review_row_preview_path(rows.fetch("delete_entity").row_uuid)
    expect(captions("review-preview-card", "delete").to_h).to include("Apply" => "Deletes the entity as listed above; this can't be undone.")

    get review_group_path(key: rows.fetch("stale_memory").group_key)
    apply = Nokogiri::HTML5(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(rows.fetch('stale_memory'))} button[title]")
    expect(apply["title"]).to eq("Applies it now, with no confirm card; Undo in the toast reverts it.")
  end

  it "says what the choice kinds' own buttons do" do
    rows = seed_every_kind
    contradiction = rows.fetch("contradiction")
    first, second = contradiction.payload.values_at("observation_id_1", "observation_id_2")
    get review_row_path(contradiction.row_uuid)
    expect(captions("review-detail-card", "contradiction").map(&:last)).to include(
      "Opens a confirm card: keeps ##{first} and marks ##{second} obsolete; Undo brings it back.",
      "Opens a confirm card: keeps ##{second} and marks ##{first} obsolete; Undo brings it back.",
      "Both facts stay as they are, and this pair isn't flagged again (Restore brings it back)."
    )

    supersede = rows.fetch("fact_supersede")
    id = supersede.payload["observation_id"]
    get review_row_path(supersede.row_uuid)
    expect(captions("review-detail-card", "fact_supersede").to_h).to include(
      "Supersede…" => "Opens a confirm card to replace ##{id} with a text you can edit; the old one stays as history, and Undo brings it back.",
      "Retire…" => "Opens a confirm card to mark ##{id} obsolete, with no replacement; Undo brings it back.",
      "Dismiss" => "The fact doesn't outdate it: nothing changes, and this pair isn't proposed again (Restore brings it back)."
    )
    get review_row_preview_path(supersede.row_uuid, fact_action: "supersede")
    expect(captions("review-preview-card", "fact_supersede").to_h).to include(
      "Supersede" => "Replaces ##{id} with this text; the old one stays as history (superseded), and Undo brings it back."
    )
    get review_row_preview_path(supersede.row_uuid, fact_action: "retire")
    expect(captions("review-preview-card", "fact_supersede").to_h).to include("Retire" => "Marks ##{id} obsolete, with no replacement; Undo brings it back.")

    get review_row_path(rows.fetch("relation_retype (choice)").row_uuid)
    expect(captions("review-detail-card", "relation_retype").to_h).to include(
      "Move under SynthGadget…" => "Opens a confirm card: the child leaves SynthApp for SynthGadget (its scope follows), and the variant edge goes; " \
                                   "Undo reverts it.",
      "Keep SynthApp…" => "Opens a confirm card: the child stays part_of SynthApp, and the variant becomes relates_to; Undo reverts it."
    )

    get review_row_path(rows.fetch("relation_review").row_uuid)
    expect(captions("review-detail-card", "relation_review").to_h).to include(
      "Dismiss" => "The relation still holds: nothing changes, and this fact isn't flagged against it again (Restore brings it back)."
    )
  end

  it "gives the group cards' actions their captions as titles, and captions the group confirm cards" do
    rows = seed_every_kind
    %w[attention kind errors scan].each do |view|
      get review_path(view: view)
      titles("review-group", view) if response.body.include?("data-testid=\"review-group\"")
    end
    get review_path(view: "kind")
    expect(titles("review-group", "kind").to_h).to include(
      "Apply high-confidence" => "Opens a confirm card for this group's relationship proposals and stale-memory rows at confidence 0.8 " \
                                 "or more (at most 100); nothing is written yet.",
      "Review" => "Lists this group's suggestions here; nothing is written.",
      "Dismiss all" => "Opens a confirm card to dismiss this group's pending suggestions (at most 100); nothing is written yet.",
      "Snooze 30 days" => "Opens a confirm card to hide this group's pending suggestions for 30 days; nothing is written yet."
    )

    key = rows.fetch("relationship_proposal").group_key
    {
      "apply" => [ "Apply", "Applies the suggestions included above, as one change; Undo in the toast reverts it." ],
      "dismiss" => [ "Dismiss", "Dismisses the suggestions included above: nothing changes in the graph, and they aren't made again " \
                                "(Undo brings them back)." ],
      "snooze" => [ "Snooze 30 days", "Hides the suggestions included above for 30 days; the next policy run after that brings them back." ]
    }.each do |op, caption|
      get review_group_preview_path(key: key, op: op, min_confidence: (ReviewDigest::HIGH_CONFIDENCE if op == "apply"))
      expect(captions("group-preview-card", op)).to eq([ caption ])
    end
  end

  it "captions Restore on a resolved row, in the card and as the resolved list's title" do
    row = seed_every_kind.fetch("relationship_proposal")
    post review_row_dismiss_path(row.row_uuid), headers: turbo

    restore = "Back to pending, its suppression lifted; an applied change stays applied (Undo reverts that)."
    get review_row_path(row.row_uuid)
    expect(captions("review-detail-card", "dismissed")).to eq([ [ "Restore", restore ] ])
    # The resolved list offers Restore once its change set can't be undone any more (Undo before).
    ChangeSet.find(row.reload.change_set_id).update_columns(undoable_until: 1.day.ago)
    get review_path(view: "resolved")
    expect(Nokogiri::HTML5(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(row)} button[title]")&.[]("title")).to eq(restore)
  end
end
