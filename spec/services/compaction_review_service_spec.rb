# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompactionReviewService, type: :service do
  let!(:source) { MemoryEntity.create!(name: "Source Task", entity_type: "Task") }
  let!(:target) { MemoryEntity.create!(name: "Target Task", entity_type: "Task") }
  let!(:from_entity) { MemoryEntity.create!(name: "Issue A", entity_type: "Issue") }
  let!(:to_entity) { MemoryEntity.create!(name: "Solution B", entity_type: "PossibleSolution") }
  let!(:project) { MemoryEntity.create!(name: "Project X", entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE) }

  let!(:report) { MaintenanceReport.create!(report_type: "compaction_review", data: { "source" => "test" }) }

  let!(:merge_row) do
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "merge-1",
      kind: "entity_merge",
      status: "active",
      signature: described_class.signature_for("entity_merge", {
        entity_a: { entity_id: source.id },
        entity_b: { entity_id: target.id }
      }),
      payload: {
        "entity_a" => { "entity_id" => source.id, "name" => source.name, "entity_type" => source.entity_type },
        "entity_b" => { "entity_id" => target.id, "name" => target.name, "entity_type" => target.entity_type },
        "cosine_distance" => 0.12,
        "score" => 0.88
      }
    )
  end

  let!(:orphan_row) do
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "orphan-1",
      kind: "orphan_parent",
      status: "active",
      signature: described_class.signature_for("orphan_parent", { entity_id: 99 }),
      payload: {
        "entity_id" => 99,
        "entity_name" => "Orphan",
        "entity_type" => "Task",
        "suggested_parents" => [
          { "project_id" => project.id, "project_name" => project.name, "score" => 0.9 }
        ],
        "score" => 0.9
      }
    )
  end

  let!(:relation_row) do
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "relation-1",
      kind: "relationship_proposal",
      status: "active",
      signature: described_class.signature_for("relationship_proposal", {
        from_entity_id: from_entity.id,
        to_entity_id: to_entity.id,
        relation_type: "solves"
      }),
      payload: {
        "from_entity_id" => from_entity.id,
        "from_name" => from_entity.name,
        "from_entity_type" => from_entity.entity_type,
        "to_entity_id" => to_entity.id,
        "to_name" => to_entity.name,
        "to_entity_type" => to_entity.entity_type,
        "relation_type" => "solves",
        "confidence_band" => "high",
        "score" => 10
      }
    )
  end

  let(:integrity_keep) do
    MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity, relation_type: "relates_to")
  end

  let(:integrity_duplicate) do
    relation = MemoryRelation.new(from_entity: to_entity, to_entity: from_entity, relation_type: "relates_to")
    relation.save!(validate: false)
    relation
  end

  let(:integrity_row) do
    payload = {
      "issue_kind" => "reverse_pair",
      "payload" => {
        "kind" => "reverse_pair",
        "keep_id" => integrity_keep.id,
        "delete_id" => integrity_duplicate.id,
        "keep" => { "id" => integrity_keep.id },
        "delete" => { "id" => integrity_duplicate.id }
      }
    }

    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "integrity-1",
      kind: "relation_integrity",
      status: "active",
      signature: described_class.signature_for("relation_integrity", payload),
      payload: payload
    )
  end

  describe ".latest_report" do
    it "returns the latest compaction review report" do
      expect(described_class.latest_report).to eq(report)
    end
  end

  describe ".items" do
    it "paginates active items with root nodes first" do
      items = described_class.items

      expect(items.count).to eq(3)
      expect(items.first.kind).to eq("orphan_parent")
    end

    it "filters ignored items" do
      described_class.ignore("merge-1")

      items = described_class.items(status: "active")
      expect(items.count).to eq(2)
      expect(items.map(&:row_uuid)).not_to include("merge-1")
    end

    it "filters by status" do
      described_class.ignore("merge-1")
      expect(described_class.items(status: "ignored").map(&:row_uuid)).to include("merge-1")
    end
  end

  describe ".find_item" do
    it "locates a row by uuid" do
      item = described_class.find_item("merge-1")
      expect(item).to eq(merge_row)
    end

    it "returns nil for an unknown uuid" do
      expect(described_class.find_item("missing")).to be_nil
    end
  end

  describe ".ignore" do
    it "marks the row as ignored" do
      expect(described_class.ignore("merge-1")[:success]).to be true
      expect(described_class.find_item("merge-1").status).to eq("ignored")
    end
  end

  describe ".edit_item" do
    it "stores editable payload overrides" do
      result = described_class.edit_item("merge-1", { "source_id" => target.id, "target_id" => source.id })

      expect(result[:success]).to be true
      merge_row.reload
      expect(merge_row.edited_payload["source_id"]).to eq(target.id)
      expect(merge_row.edited_payload["target_id"]).to eq(source.id)
    end

    it "rejects edits to non-existent entities" do
      result = described_class.edit_item("merge-1", { "source_id" => 0 })

      expect(result[:success]).to be false
      expect(result[:error]).to match(/Entity.*does not exist/)
    end
  end

  describe ".apply" do
    it "merges two task entities" do
      result = described_class.apply("merge-1", { "source_id" => source.id, "target_id" => target.id })

      expect(result[:success]).to be true
      expect(MemoryEntity.find_by(id: source.id)).to be_nil
      expect(MemoryEntity.find_by(id: target.id)).to be_present
      expect(described_class.find_item("merge-1").status).to eq("approved")
    end

    it "creates a relationship between two entities" do
      result = described_class.apply("relation-1", { "from_id" => from_entity.id, "to_id" => to_entity.id, "relation_type" => "solves" })

      expect(result[:success]).to be true
      expect(MemoryRelation.find_by(from_entity_id: from_entity.id, to_entity_id: to_entity.id, relation_type: "solves")).to be_present
      expect(described_class.find_item("relation-1").status).to eq("approved")
    end

    it "applies a relation integrity repair and tolerates stale deleted relations" do
      integrity_row
      result = described_class.apply("integrity-1")

      expect(result[:success]).to be true
      expect(result[:deleted_relation_ids]).to eq([ integrity_duplicate.id ])
      expect(MemoryRelation.find_by(id: integrity_keep.id)).to be_present
      expect(MemoryRelation.find_by(id: integrity_duplicate.id)).to be_nil
      expect(described_class.find_item("integrity-1").status).to eq("approved")

      stale_row = integrity_row.dup
      stale_row.row_uuid = "integrity-stale"
      stale_row.status = "active"
      stale_row.save!
      expect(described_class.apply("integrity-stale")[:success]).to be true
    end

    it "refuses to apply a dismissed or approved row" do
      row = described_class.find_item("relation-1")

      row.update!(status: "dismissed", dismissed_at: Time.current)
      expect(described_class.apply("relation-1", { "from_id" => from_entity.id, "to_id" => to_entity.id, "relation_type" => "solves" })[:success]).to be false

      row.update!(status: "approved", applied_at: Time.current)
      expect(described_class.apply("relation-1", { "from_id" => from_entity.id, "to_id" => to_entity.id, "relation_type" => "solves" })[:success]).to be false
    end

    it "re-checks the row status inside the lock before applying" do
      row = described_class.find_item("relation-1")
      allow(described_class).to receive(:find_item).and_return(row)
      allow(row).to receive(:with_lock) do |&block|
        row.update!(status: "dismissed", dismissed_at: Time.current)
        block.call
      end

      result = described_class.apply("relation-1", { "from_id" => from_entity.id, "to_id" => to_entity.id, "relation_type" => "solves" })

      expect(result[:success]).to be false
      expect(result[:error]).to include("not actionable")
      expect(MemoryRelation.find_by(from_entity_id: from_entity.id, to_entity_id: to_entity.id, relation_type: "solves")).to be_nil
    end

    it "rolls the edge back when membership sync fails — failure must not orphan the row" do
      part_of_edge = MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity,
                                            relation_type: "part_of")
      delete_row = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "del-rel-1",
        kind: "delete_relation",
        status: "active",
        signature: described_class.signature_for("delete_relation", { relation_id: part_of_edge.id }),
        payload: { "relation_id" => part_of_edge.id }
      )
      allow(ProjectMembership).to receive(:sync!).and_raise(ProjectMembership::Collision, "name clash")

      result = described_class.apply(delete_row.row_uuid)

      expect(result[:success]).to be false
      expect(MemoryRelation.find_by(id: part_of_edge.id)).to be_present
    end

    it "applying a part_of relationship_proposal syncs the child's project scope" do
      project = MemoryEntity.create!(name: "PropProj", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "PropOrphan", entity_type: "Class")
      proposal = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "prop-partof-1",
        kind: "relationship_proposal",
        status: "active",
        signature: described_class.signature_for(
          "relationship_proposal",
          { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
        ),
        payload: { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
      )

      result = described_class.apply(proposal.row_uuid)

      expect(result[:success]).to be true
      expect(orphan.reload.project_id).to eq(project.id)
    end

    it "applies a part_of proposal with the advisory lock BEFORE the transaction" do
      project = MemoryEntity.create!(name: "PropOrdProj", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "PropOrdOrphan", entity_type: "Class")
      proposal = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "prop-partof-ord",
        kind: "relationship_proposal",
        status: "active",
        signature: described_class.signature_for(
          "relationship_proposal",
          { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
        ),
        payload: { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
      )

      # Without the outer with_membership_lock the first GET_LOCK observed is
      # reassign!'s — issued INSIDE the transaction (the deadlock ordering).
      excess = open_transactions_at_get_lock { described_class.apply(proposal.row_uuid) }
      expect(excess).to eq(0)
    end

    it "rolls the created part_of edge back when membership sync fails" do
      project = MemoryEntity.create!(name: "PropRbProj", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "PropRbOrphan", entity_type: "Class")
      proposal = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "prop-partof-rb",
        kind: "relationship_proposal",
        status: "active",
        signature: described_class.signature_for(
          "relationship_proposal",
          { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
        ),
        payload: { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
      )

      # create + sync must be atomic: a sync failure that left the edge
      # committed would stamp nothing yet report "failed".
      allow(ProjectMembership).to receive(:sync!).and_raise(ProjectMembership::Collision, "name clash")
      result = described_class.apply(proposal.row_uuid)

      expect(result[:success]).to be false
      expect(MemoryRelation.exists?(from_entity: orphan, to_entity: project,
                                    relation_type: "part_of")).to be false
      expect(orphan.reload.project_id).to be_nil
    end

    it "a part_of proposal under a held lock fails the apply and writes nothing" do
      stub_const("ProjectMembership::LOCK_TIMEOUT_SECONDS", 0)
      project = MemoryEntity.create!(name: "PropLockProj", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "PropLockOrphan", entity_type: "Class")
      proposal = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "prop-partof-lock",
        kind: "relationship_proposal",
        status: "active",
        signature: described_class.signature_for(
          "relationship_proposal",
          { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
        ),
        payload: { "from_id" => orphan.id, "to_id" => project.id, "relation_type" => "part_of" }
      )

      conn = ActiveRecord::Base.connection
      name = ProjectMembership.lock_name(conn)
      holder = stub_const("PropLockHolder",
                          Class.new(ActiveRecord::Base) { self.abstract_class = true })
      holder.establish_connection(ActiveRecord::Base.connection_db_config)
      holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(name)}, 5)")

      # The busy advisory lock surfaces as a raised LockTimeout — callers
      # map it to the transient "retry shortly" concurrency envelope.
      expect { described_class.apply(proposal.row_uuid) }
        .to raise_error(ProjectMembership::LockTimeout)
      expect(MemoryRelation.exists?(from_entity: orphan, to_entity: project,
                                    relation_type: "part_of")).to be false
      expect(orphan.reload.project_id).to be_nil
    ensure
      holder.connection.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})") if holder&.connection
      holder.connection_pool&.disconnect! if holder
    end

    it "rolls the edge back on a LockTimeout — a busy lock is a failed apply, not a partial write" do
      part_of_edge = MemoryRelation.create!(from_entity: from_entity, to_entity: to_entity,
                                            relation_type: "part_of")
      delete_row = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "del-rel-lock",
        kind: "delete_relation",
        status: "active",
        signature: described_class.signature_for("delete_relation", { relation_id: part_of_edge.id }),
        payload: { "relation_id" => part_of_edge.id }
      )
      allow(ProjectMembership).to receive(:sync!).and_raise(ProjectMembership::LockTimeout, "lock held")

      result = described_class.apply(delete_row.row_uuid)

      expect(result[:success]).to be false
      expect(MemoryRelation.find_by(id: part_of_edge.id)).to be_present
    end
  end

  describe "relation integrity review rows" do
    it "uses a stable signature for every selected duplicate relation" do
      payload = {
        issue_kind: "merge_collision",
        payload: { keep_id: 10, delete_ids: [ 13, 11, 12 ] }
      }

      expect(described_class.signature_for("relation_integrity", payload))
        .to eq("relation_integrity|merge_collision|10|11-12-13")
    end

    it "can dismiss and restore a queued integrity repair" do
      integrity_row

      expect(described_class.dismiss("integrity-1")[:success]).to be(true)
      expect(integrity_row.reload.status).to eq("dismissed")
      expect(described_class.restore("integrity-1")[:success]).to be(true)
      expect(integrity_row.reload.status).to eq("active")
    end
  end

  describe ".dismiss" do
    it "marks the row dismissed and records a suppression signature" do
      expect(described_class.dismiss("merge-1")[:success]).to be true

      merge_row.reload
      expect(merge_row.status).to eq("dismissed")
      expect(MaintenanceReportSuppression.suppressed?("compaction_review", merge_row.signature)).to be true
    end

    it "keeps an edited suggestion's original proposal suppressed after the row is pruned" do
      original_payload = relation_row.payload
      described_class.edit_item("relation-1", { "relation_type" => "part_of" })
      described_class.dismiss("relation-1")
      relation_row.reload.update_columns(updated_at: 31.days.ago)
      AppSettings.compaction_review_row_retention_days = 30

      MaintenanceReportRowCleanupJob.perform_now

      expect(MaintenanceReportRow.find_by(row_uuid: "relation-1")).to be_nil
      expect(described_class.suppressed?("relationship_proposal", original_payload)).to be true
      expect(described_class.suppressed?("relationship_proposal", original_payload.merge("relation_type" => "part_of"))).to be true
    end
  end

  describe ".restore" do
    it "sets the row back to active" do
      described_class.dismiss("merge-1")
      expect(described_class.restore("merge-1")[:success]).to be true
      expect(described_class.find_item("merge-1").status).to eq("active")
    end

    it "clears the suppressions of both the original and the edited proposal" do
      described_class.edit_item("relation-1", { "relation_type" => "part_of" })
      described_class.dismiss("relation-1")

      described_class.restore("relation-1")

      expect(MaintenanceReportSuppression.where(report_type: "compaction_review")).not_to exist
    end
  end

  describe ".seed_report" do
    let!(:seed_source) { MemoryEntity.create!(name: "Seed Source", entity_type: "Task") }
    let!(:seed_target) { MemoryEntity.create!(name: "Seed Target", entity_type: "Task") }

    it "creates rows for new suggestions and skips duplicates" do
      items = [
        {
          id: "new-1",
          kind: "entity_merge",
          entity_a: { entity_id: seed_source.id, name: seed_source.name, entity_type: seed_source.entity_type },
          entity_b: { entity_id: seed_target.id, name: seed_target.name, entity_type: seed_target.entity_type },
          cosine_distance: 0.15,
          score: 0.85
        }
      ]

      rows = described_class.seed_report(report_type: "compaction_review", source: "test", items: items)
      expect(rows.size).to eq(1)

      # re-seeding the same pair is skipped because an active row already exists
      rows = described_class.seed_report(report_type: "compaction_review", source: "test", items: items)
      expect(rows).to be_empty
    end

    it "skips suppressed suggestions" do
      described_class.dismiss("merge-1")
      merge_row.destroy!

      items = [
        {
          id: "new-2",
          kind: "entity_merge",
          entity_a: { entity_id: source.id, name: source.name, entity_type: source.entity_type },
          entity_b: { entity_id: target.id, name: target.name, entity_type: target.entity_type },
          cosine_distance: 0.12,
          score: 0.88
        }
      ]

      rows = described_class.seed_report(report_type: "compaction_review", source: "test", items: items)
      expect(rows).to be_empty
    end
  end

  describe ".absorb_stale_memory?" do
    let(:scan_entity) { MemoryEntity.create!(name: "ScanEnt", entity_type: "Issue") }
    let(:obs1) { MemoryObservation.create!(memory_entity: scan_entity, content: "obs 1") }
    let(:obs2) { MemoryObservation.create!(memory_entity: scan_entity, content: "obs 2") }
    let(:obs3) { MemoryObservation.create!(memory_entity: scan_entity, content: "obs 3") }

    def stale_row(uuid, obs_ids, edited: nil, entity: scan_entity)
      payload = {
        "kind" => "stale_memory",
        "entity_id" => entity.id,
        "signal" => "valid_until_elapsed",
        "observation_ids" => obs_ids
      }
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "stale_memory_scan",
        row_uuid: uuid,
        kind: "stale_memory",
        status: "active",
        signature: described_class.signature_for("stale_memory", payload),
        payload: payload,
        edited_payload: edited
      )
    end

    it "merges a re-detection into the pending row and retires duplicates" do
      keep = stale_row("sm-1", [ obs1.id ])
      duplicate = stale_row("sm-2", [ obs2.id ])
      payload = {
        kind: "stale_memory", entity_id: scan_entity.id,
        signal: "valid_until_elapsed", observation_ids: [ obs3.id ]
      }

      expect(described_class.absorb_stale_memory?("stale_memory_scan", payload)).to be true

      keep.reload
      expect(keep.effective_payload["observation_ids"].map(&:to_i)).to eq([ obs1.id, obs2.id, obs3.id ].sort)
      expect(duplicate.reload.status).to eq("ignored")
    end

    it "merges new observation ids into edited_payload so operator edits win" do
      keep = stale_row("sm-1", [ obs1.id ], edited: { "observation_ids" => [ obs1.id ], "note" => "keep" })
      payload = {
        kind: "stale_memory", entity_id: scan_entity.id,
        signal: "valid_until_elapsed", observation_ids: [ obs2.id ]
      }

      described_class.absorb_stale_memory?("stale_memory_scan", payload)

      keep.reload
      expect(keep.edited_payload["observation_ids"].map(&:to_i)).to eq([ obs1.id, obs2.id ])
      expect(keep.edited_payload["note"]).to eq("keep")
    end

    it "does not resurrect a suppressed merged signature" do
      keep = stale_row("sm-1", [ obs1.id ])
      merged_sig = described_class.signature_for(
        "stale_memory",
        "entity_id" => scan_entity.id, "signal" => "valid_until_elapsed",
        "observation_ids" => [ obs1.id, obs2.id ].sort
      )
      MaintenanceReportSuppression.create!(
        report_type: "stale_memory_scan",
        signature: merged_sig,
        kind: "stale_memory",
        dismissed_at: Time.current
      )
      payload = {
        kind: "stale_memory", entity_id: scan_entity.id,
        signal: "valid_until_elapsed", observation_ids: [ obs2.id ]
      }

      described_class.absorb_stale_memory?("stale_memory_scan", payload)

      expect(keep.reload.effective_payload["observation_ids"].map(&:to_i)).to eq([ obs1.id ])
    end

    it "reads the candidates with a row lock" do
      stale_row("sm-1", [ obs1.id ])
      payload = {
        kind: "stale_memory", entity_id: scan_entity.id,
        signal: "valid_until_elapsed", observation_ids: [ obs2.id ]
      }

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, event|
        queries << event[:sql]
      end
      described_class.absorb_stale_memory?("stale_memory_scan", payload)
      ActiveSupport::Notifications.unsubscribe(subscriber)

      selects = queries.select { |sql| sql.match?(/FROM `?maintenance_report_rows`?/i) }
      expect(selects).not_to be_empty
      expect(selects).to all(match(/FOR UPDATE/i))
      # The candidate SELECT must narrow on the indexed generated column —
      # a WHERE without an index would still X-lock every scanned row.
      expect(selects.grep(/stale_entity_id/i)).not_to be_empty
      # FORCE INDEX is load-bearing, not decorative: on real data the
      # optimizer prefers the broader report_type index, which X-locks the
      # whole queue again. Dropping the hint must fail this spec.
      expect(selects).to include(a_string_matching(/FORCE INDEX \(index_mrr_stale_candidates\)/i))
    end

    it "hits the stale-entity index for the candidate locking read" do
      15.times { stale_row("sm-pad-#{_1}", [ obs1.id ]) }
      other = MemoryEntity.create!(name: "OtherPad", entity_type: "Issue")
      15.times { stale_row("sm-other-#{_1}", [ obs1.id ], entity: other) }

      sql = MaintenanceReportRow.by_report_type("stale_memory_scan").active
                                .where(kind: "stale_memory", stale_entity_id: scan_entity.id)
                                .order(:id).lock(true)
                                .from("#{MaintenanceReportRow.quoted_table_name} FORCE INDEX (index_mrr_stale_candidates)")
                                .to_sql
      plan = ActiveRecord::Base.connection.select_one("EXPLAIN #{sql}")

      expect(plan["key"]).to eq("index_mrr_stale_candidates")
    end

    it "absorbs a row whose entity_id only matches via an operator edit" do
      other_entity = MemoryEntity.create!(name: "OtherEnt", entity_type: "Issue")
      payload = {
        "kind" => "stale_memory", "entity_id" => other_entity.id,
        "signal" => "valid_until_elapsed", "observation_ids" => [ obs1.id ]
      }
      row = MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "stale_memory_scan",
        row_uuid: "sm-edit",
        kind: "stale_memory",
        status: "active",
        signature: described_class.signature_for("stale_memory", payload),
        payload: payload,
        edited_payload: { "entity_id" => scan_entity.id }
      )
      fresh = {
        kind: "stale_memory", entity_id: scan_entity.id,
        signal: "valid_until_elapsed", observation_ids: [ obs2.id ]
      }

      expect(described_class.absorb_stale_memory?("stale_memory_scan", fresh)).to be true
      expect(row.reload.edited_payload["observation_ids"].map(&:to_i))
        .to eq([ obs1.id, obs2.id ].sort)
    end

    it "never merges into or retires a row that settled before the lock" do
      settled = stale_row("sm-1", [ obs1.id ])
      active = stale_row("sm-2", [ obs2.id ])
      payload = {
        kind: "stale_memory", entity_id: scan_entity.id,
        signal: "valid_until_elapsed", observation_ids: [ obs3.id ]
      }
      # `settled` was active when the locking read ran but got approved
      # before the merge — the in-memory filter must still drop it.
      allow_any_instance_of(MaintenanceReportRow).to receive(:active?) do |row|
        row.id == settled.id ? false : row.status == "active"
      end

      expect(described_class.absorb_stale_memory?("stale_memory_scan", payload)).to be true

      expect(settled.reload.status).to eq("active")
      expect(settled.effective_payload["observation_ids"].map(&:to_i)).to eq([ obs1.id ])
      expect(active.reload.effective_payload["observation_ids"].map(&:to_i))
        .to eq([ obs2.id, obs3.id ].sort)
    end

    it "does not touch a row that was already approved" do
      approved = stale_row("sm-1", [ obs1.id ])
      approved.update!(status: "approved")
      payload = {
        kind: "stale_memory", entity_id: scan_entity.id,
        signal: "valid_until_elapsed", observation_ids: [ obs2.id ]
      }

      expect(described_class.absorb_stale_memory?("stale_memory_scan", payload)).to be false
      expect(approved.reload.status).to eq("approved")
      expect(approved.effective_payload["observation_ids"].map(&:to_i)).to eq([ obs1.id ])
    end

    context "when a locking read hits ER_CHECKREAD" do
      def checkread_error
        mysql_error = Mysql2::Error.new(
          "Record has changed since last read in table 'maintenance_report_rows'"
        )
        allow(mysql_error).to receive(:error_number).and_return(1020)
        error = ActiveRecord::StatementInvalid.new(mysql_error.message)
        allow(error).to receive(:cause).and_return(mysql_error)
        error
      end

      let(:stale_payload) do
        {
          kind: "stale_memory", entity_id: scan_entity.id,
          signal: "valid_until_elapsed", observation_ids: [ obs3.id ]
        }
      end

      it "retries the seed once and still absorbs the item" do
        keep = stale_row("sm-1", [ obs1.id ])
        attempts = 0
        allow(described_class).to receive(:stale_memory_candidates).and_wrap_original do |m, *args|
          attempts += 1
          raise checkread_error if attempts == 1

          m.call(*args)
        end

        rows = described_class.seed_report(
          report_type: "stale_memory_scan", source: "test", items: [ stale_payload ]
        )

        expect(rows).to be_empty
        expect(keep.reload.effective_payload["observation_ids"].map(&:to_i))
          .to eq([ obs1.id, obs3.id ].sort)
      end

      it "propagates after the bounded retries are exhausted" do
        stale_row("sm-1", [ obs1.id ])
        calls = 0
        allow(described_class).to receive(:stale_memory_candidates) do
          calls += 1
          raise checkread_error
        end

        expect {
          described_class.seed_report(
            report_type: "stale_memory_scan", source: "test", items: [ stale_payload ]
          )
        }.to raise_error(ActiveRecord::StatementInvalid)
        expect(calls).to eq(CompactionReviewService::CHECKREAD_MAX_ATTEMPTS)
      end

      it "does not retry on unrelated statement errors" do
        stale_row("sm-1", [ obs1.id ])
        calls = 0
        allow(described_class).to receive(:stale_memory_candidates) do
          calls += 1
          raise ActiveRecord::StatementInvalid, "some other failure"
        end

        expect {
          described_class.seed_report(
            report_type: "stale_memory_scan", source: "test", items: [ stale_payload ]
          )
        }.to raise_error(ActiveRecord::StatementInvalid)
        expect(calls).to eq(1)
      end

      # Deadlock (errno 1213) is a TransactionRollbackError — NOT a
      # StatementInvalid — so it needs explicit handling in the retry. An
      # apply's status update moving an index entry into a seed's
      # next-key-locked range is the C2 collision in exception form.
      it "retries on ActiveRecord::Deadlocked and still absorbs the item" do
        keep = stale_row("sm-1", [ obs1.id ])
        attempts = 0
        allow(described_class).to receive(:stale_memory_candidates).and_wrap_original do |m, *args|
          attempts += 1
          raise ActiveRecord::Deadlocked, "deadlock found" if attempts == 1

          m.call(*args)
        end

        rows = described_class.seed_report(
          report_type: "stale_memory_scan", source: "test", items: [ stale_payload ]
        )

        expect(rows).to be_empty
        expect(keep.reload.effective_payload["observation_ids"].map(&:to_i))
          .to eq([ obs1.id, obs3.id ].sort)
      end

      it "propagates a persistent deadlock after the bounded retries" do
        stale_row("sm-1", [ obs1.id ])
        calls = 0
        allow(described_class).to receive(:stale_memory_candidates) do
          calls += 1
          raise ActiveRecord::Deadlocked, "deadlock found"
        end

        expect {
          described_class.seed_report(
            report_type: "stale_memory_scan", source: "test", items: [ stale_payload ]
          )
        }.to raise_error(ActiveRecord::Deadlocked)
        expect(calls).to eq(CompactionReviewService::CHECKREAD_MAX_ATTEMPTS)
      end

      it "backs off between retried attempts" do
        allow(described_class).to receive(:sleep)
        stale_row("sm-1", [ obs1.id ])
        attempts = 0
        allow(described_class).to receive(:stale_memory_candidates).and_wrap_original do |m, *args|
          attempts += 1
          raise checkread_error if attempts <= 2

          m.call(*args)
        end

        described_class.seed_report(
          report_type: "stale_memory_scan", source: "test", items: [ stale_payload ]
        )

        # Attempts 1 and 2 fail, attempt 3 succeeds — both backoffs ran.
        expect(described_class).to have_received(:sleep).with(0.05)
        expect(described_class).to have_received(:sleep).with(0.1)
      end
    end
  end

  describe ".apply_action" do
    it "returns an error for unknown kinds" do
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "unknown-1",
        kind: "entity_error",
        status: "active",
        signature: "entity_error|1",
        payload: { "entity_id" => 1, "error_message" => "boom" }
      )

      result = described_class.apply("unknown-1")
      expect(result[:success]).to be false
    end
  end

  describe ".items with q" do
    it "matches names and ids inside the payload, case-insensitively" do
      expect(described_class.items(q: "source task").map(&:row_uuid)).to include("merge-1")
      expect(described_class.items(q: "SOURCE TASK").map(&:row_uuid)).to include("merge-1")
    end

    it "matches the kind string and returns nothing on a miss" do
      expect(described_class.items(q: "orphan_parent").map(&:row_uuid)).to eq([ "orphan-1" ])
      expect(described_class.items(q: "zzz-no-such-text")).to be_empty
    end
  end

  describe ".kind_counts" do
    it "groups active queue rows by kind" do
      counts = described_class.kind_counts
      expect(counts["entity_merge"]).to eq(1)
      expect(counts["orphan_parent"]).to eq(1)
      expect(counts["relationship_proposal"]).to eq(1)
    end
  end

  describe ".bulk_apply" do
    let!(:proposable_target) { MemoryEntity.create!(name: "Other B", entity_type: "PossibleSolution") }

    it "applies selected actionable rows and skips non-actionable ones" do
      described_class.dismiss("orphan-1")

      result = described_class.bulk_apply([ "merge-1", "orphan-1", "rel-1" ])

      expect(result[:success]).to be true
      expect(result[:message]).to include("skipped")
      expect(described_class.find_item("orphan-1").status).to eq("dismissed")
    end

    it "reports per-row failures without aborting the batch" do
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "ghost-1",
        kind: "delete_entity",
        status: "active",
        signature: "delete_entity|999999",
        payload: { "entity_id" => 999_999, "entity_name" => "Ghost" }
      )

      result = described_class.bulk_apply([ "merge-1", "ghost-1" ])

      expect(result[:success]).to be false
      expect(result[:message]).to include("failed")
      expect(result[:message]).to include("Entity not found")
    end

    it "refuses an empty selection" do
      expect(described_class.bulk_apply([])[:success]).to be false
    end
  end

  describe ".delete_children_info" do
    let!(:parent_entity) { MemoryEntity.create!(name: "Parent C", entity_type: "Class") }
    let!(:queued_child) { MemoryEntity.create!(name: "Queued Child", entity_type: "Method") }
    let!(:lone_child) { MemoryEntity.create!(name: "Lone Child", entity_type: "Method") }
    let!(:delete_row) do
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "del-1",
        kind: "delete_entity",
        status: "active",
        signature: "delete_entity|#{parent_entity.id}",
        payload: { "entity_id" => parent_entity.id, "entity_name" => parent_entity.name }
      )
    end

    before do
      MemoryRelation.create!(from_entity: queued_child, to_entity: parent_entity, relation_type: "part_of")
      MemoryRelation.create!(from_entity: lone_child, to_entity: parent_entity, relation_type: "part_of")
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: "compaction_review",
        row_uuid: "del-child",
        kind: "delete_entity",
        status: "active",
        signature: "delete_entity|#{queued_child.id}",
        payload: { "entity_id" => queued_child.id, "entity_name" => queued_child.name }
      )
    end

    it "splits children into queued-for-deletion vs parentless" do
      info = described_class.delete_children_info(report_type: "compaction_review", items: [ delete_row ])

      expect(info[parent_entity.id]).to eq(queued: 1, parentless: 1)
    end

    it "ignores dismissed delete rows when counting queued children" do
      described_class.dismiss("del-child")

      info = described_class.delete_children_info(report_type: "compaction_review", items: [ delete_row ])

      expect(info[parent_entity.id]).to eq(queued: 0, parentless: 2)
    end

    it "returns empty for pages without delete_entity rows" do
      expect(described_class.delete_children_info(report_type: "compaction_review", items: [ merge_row ])).to eq({})
    end
  end

  # Real two-connection race: fixtures must be COMMITTED to be visible to
  # other connections, so setup/cleanup use before/after(:context), which
  # run outside the per-example transaction. Rows are cleaned up manually.
  describe "concurrent cross-entity stale seeds" do
    # The C2 example MUST run without the fixture transaction: when a
    # checkread/deadlock kills the seed's InnoDB txn, the bounded retry has
    # to open a fresh real transaction — inside a rolled-back fixture txn
    # the retry dies on "SAVEPOINT does not exist", an artifact, not the
    # production behaviour.
    uses_transaction "a seed waiting on an apply's row lock commits cleanly (C2)"

    before(:context) do
      @entity_a = MemoryEntity.create!(name: "RaceEntA", entity_type: "Issue")
      @entity_b = MemoryEntity.create!(name: "RaceEntB", entity_type: "Issue")
      @entity_c = MemoryEntity.create!(name: "RaceEntC", entity_type: "Issue")
      @obs_a = MemoryObservation.create!(memory_entity: @entity_a, content: "seed obs a")
      @obs_b = MemoryObservation.create!(memory_entity: @entity_b, content: "seed obs b")
      @obs_c = MemoryObservation.create!(memory_entity: @entity_c, content: "seed obs c")
      # A queue of unrelated stale rows widens the FOR UPDATE scan enough
      # for the cross-entity collision to fire reliably on a regression —
      # without it, two threads slip past each other before the window
      # opens (Graphy's probe needed ~200 scanned rows, 6/6 crashes). The
      # pads get LOW ids and the race rows HIGH ids: under a whole-queue
      # scan the racing seed locks hundreds of rows before reaching the
      # other thread's keeper — a wide window for its commits to land.
      pad_entity = MemoryEntity.create!(name: "RacePad", entity_type: "Issue")
      250.times { |i| seeded_stale_row(pad_entity, @obs_a, "race-pad-#{i}") }
      # Pre-existing active rows so each seed ABSORBS (updates a row)
      # rather than only inserting — the committed update is what trips
      # ER_CHECKREAD on a racing FOR UPDATE scan.
      seeded_stale_row(@entity_a, @obs_a, "race-a")
      seeded_stale_row(@entity_b, @obs_b, "race-b")
      # race-c2 belongs only to the C2 spec, which approves it — keeping it
      # separate means that spec can't pollute race-a for the others.
      seeded_stale_row(@entity_c, @obs_c, "race-c2")
    end

    after(:context) do
      MaintenanceReportRow.where(report_type: "stale_memory_scan").delete_all
      MaintenanceReportSuppression.where(report_type: "stale_memory_scan").delete_all
      MaintenanceReport.where(report_type: "stale_memory_scan").delete_all
      MemoryEntity.where(id: [ @entity_a.id, @entity_b.id, @entity_c.id ]).destroy_all
      MemoryEntity.where(name: "RacePad").destroy_all
    end

    def seeded_stale_row(entity, obs, uuid)
      payload = {
        "kind" => "stale_memory", "entity_id" => entity.id,
        "signal" => "valid_until_elapsed", "observation_ids" => [ obs.id ]
      }
      MaintenanceReportRow.create!(
        maintenance_report: MaintenanceReport.create!(report_type: "stale_memory_scan", data: { "source" => "test" }),
        report_type: "stale_memory_scan",
        row_uuid: uuid,
        kind: "stale_memory",
        status: "active",
        signature: described_class.signature_for("stale_memory", payload),
        payload: payload
      )
    end

    # A real second DB session. Transactional fixtures pin ActiveRecord's
    # pool across ALL threads (so fixture rows stay visible), which means a
    # second with_connection is the SAME InnoDB session — its locks are its
    # own and nothing ever blocks or collides. A raw Mysql2 client bypasses
    # the pinning entirely.
    def race_db_client
      cfg = ActiveRecord::Base.connection_db_config.configuration_hash
      Mysql2::Client.new(
        cfg.slice(:host, :socket, :port, :username, :password, :database).compact
      )
    end

    it "holds locks only on its own entity's rows while a seed is in flight" do
      # Deterministic version of Graphy's xent.rb probe: while a seed holds
      # its candidate locks, a locking read on ANOTHER entity's stale row
      # must not wait. Under the old whole-queue scan the NOWAIT probe
      # fails instantly (race-b is X-locked); under the entity-scoped index
      # range it succeeds because race-b is never locked.
      race_b_id = MaintenanceReportRow.find_by!(row_uuid: "race-b").id
      locks_taken = Queue.new
      probe = Queue.new

      allow(described_class).to receive(:stale_memory_candidates).and_wrap_original do |original, *args|
        rows = original.call(*args) # FOR UPDATE locks are held until commit
        locks_taken << true
        sleep(0.3)
        rows
      end

      writer = Thread.new do
        client = race_db_client
        locks_taken.pop
        begin
          client.query("SELECT id FROM maintenance_report_rows WHERE id = #{race_b_id} FOR UPDATE NOWAIT")
          probe << :ok
        rescue Mysql2::Error => e
          probe << e
        ensure
          client.close
        end
      end

      obs = MemoryObservation.create!(memory_entity: @entity_a, content: "seed while writer probes")
      described_class.seed_report(
        report_type: "stale_memory_scan", source: "test",
        items: [ { kind: "stale_memory", entity_id: @entity_a.id,
                   signal: "valid_until_elapsed",
                   observation_ids: [ obs.id ] } ]
      )
      writer.join

      expect(probe.pop).to eq(:ok)
    end

    it "a seed waiting on an apply's row lock commits cleanly (C2)" do
      # H1 C2 on two real sessions: an apply holds race-c2's record lock, a
      # seed for the SAME entity queues behind it, and the apply then moves
      # the row's status. If `status` were still an index column, that move
      # would insert into a gap the seed next-key locked — InnoDB resolves
      # it by deadlocking the seed (errno 1213, Graphy's conc2.rb 5/5).
      # With (stale_entity_id, report_type) the status move changes no index
      # entry: the seed waits, possibly retries once on ER_CHECKREAD, sees
      # the row approved, and seeds a NEW row.
      race_c2_id = MaintenanceReportRow.find_by!(row_uuid: "race-c2").id
      lock_held = Queue.new
      holder_errors = Queue.new

      holder = Thread.new do
        client = race_db_client
        begin
          client.query("BEGIN")
          client.query("SELECT id FROM maintenance_report_rows WHERE id = #{race_c2_id} FOR UPDATE")
          lock_held << true
          sleep(0.4) # let the seed's FOR UPDATE queue on this record lock
          client.query("UPDATE maintenance_report_rows SET status = 'approved' WHERE id = #{race_c2_id}")
          client.query("COMMIT")
        rescue Mysql2::Error => e
          holder_errors << e
        ensure
          client.close
        end
      end

      candidate_calls = 0
      raised_in_scan = []
      allow(described_class).to receive(:stale_memory_candidates).and_wrap_original do |original, *args|
        candidate_calls += 1
        original.call(*args)
      rescue StandardError => e
        raised_in_scan << e.class
        raise
      end

      obs = MemoryObservation.create!(memory_entity: @entity_c, content: "seeded while apply holds the row")
      lock_held.pop
      rows = described_class.seed_report(
        report_type: "stale_memory_scan", source: "test",
        items: [ { kind: "stale_memory", entity_id: @entity_c.id,
                   signal: "valid_until_elapsed",
                   observation_ids: [ obs.id ] } ]
      )
      holder.join

      expect(holder_errors).to be_empty
      # The seed must never see a deadlock surface — a Deadlocked escaping
      # the scan means `status` is back in the stale-candidate index (the
      # retried second attempt is what a 1213/1020 would look like, so at
      # most two locking scans may run).
      expect(raised_in_scan).not_to include(ActiveRecord::Deadlocked)
      expect(candidate_calls).to be <= 2
      # The apply won: race-c2 is approved and untouched by the absorb, and
      # the new observation got its own fresh pending row instead.
      expect(MaintenanceReportRow.find_by!(row_uuid: "race-c2").status).to eq("approved")
      expect(rows.size).to eq(1)
      expect(rows.first.effective_payload["observation_ids"]).to eq([ obs.id ])
    ensure
      # uses_transaction commits everything this example touches — even the
      # shared let! fixtures — so remove them by hand or the neighbouring
      # examples see a polluted table.
      MaintenanceReportRow.where(report_type: "compaction_review").delete_all
      MaintenanceReport.where(report_type: "compaction_review").delete_all
      MemoryEntity.where(
        name: [ "Source Task", "Target Task", "Issue A", "Solution B", "Project X" ]
      ).destroy_all
    end

    it "never crashes with ER_CHECKREAD while a writer touches another entity's row" do
      # Graphy's xent3.rb shape: commits on entity B's stale row racing a
      # seed on entity A. Under the old whole-queue scan a commit landing
      # inside a seed's read window aborts its FOR UPDATE (ER_CHECKREAD);
      # with the entity-scoped index range there is no shared lock surface,
      # so seeds deterministically complete.
      race_b_id = MaintenanceReportRow.find_by!(row_uuid: "race-b").id
      base = MaintenanceReportRow.find_by!(row_uuid: "race-a")
                               .effective_payload["observation_ids"].size
      stop = false
      errors = Queue.new

      writer = Thread.new do
        client = race_db_client
        client.query("SET SESSION innodb_lock_wait_timeout = 1")
        i = 0
        until stop
          begin
            client.query(
              "UPDATE maintenance_report_rows SET resolution_reason = \"beat-#{i += 1}\" " \
              "WHERE id = #{race_b_id}"
            )
          rescue Mysql2::Error
            # Lock wait on a row the seed holds — retry on the next beat.
          end
          sleep(0.002)
        end
        client.close
      end

      8.times do |i|
        obs = MemoryObservation.create!(memory_entity: @entity_a, content: "raced obs #{i}")
        described_class.seed_report(
          report_type: "stale_memory_scan", source: "test",
          items: [ { kind: "stale_memory", entity_id: @entity_a.id,
                     signal: "valid_until_elapsed",
                     observation_ids: [ obs.id ] } ]
        )
      rescue ActiveRecord::StatementInvalid => e
        errors << e
      end
      stop = true
      writer.join

      expect(errors).to be_empty
      row = MaintenanceReportRow.find_by!(row_uuid: "race-a")
      expect(row.effective_payload["observation_ids"].size).to eq(base + 8)
    end
  end
end
