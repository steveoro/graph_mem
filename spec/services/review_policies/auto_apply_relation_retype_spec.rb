# frozen_string_literal: true

require "rails_helper"

# Dream State R1b (plan item 4): off by default; applies relation_retype "swap" rows only, and only
# when no fact of the project names the library with an ownership phrase.
RSpec.describe ReviewPolicies::AutoApplyRelationRetype do
  let!(:app) { fs_project!("SynthApp") }
  let!(:library) { fs_member!(app, "SynthLib", "Gem") }
  let(:part_of) { MemoryRelation.find_by!(from_entity_id: library.id, relation_type: "part_of") }

  after { AppSettings.where(var: "enable_auto_apply_relation_retype").delete_all }

  def enable! = AppSettings.enable_auto_apply_relation_retype = true

  def seed(item)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole
  end

  def swap_row(relation = part_of)
    names = MemoryEntity.where(id: [ relation.from_entity_id, relation.to_entity_id ]).pluck(:id, :name).to_h
    seed(CompactionReviewApplier::RelationRetypeDependency.swap_item(relation, names, evidence: { entity_type: "Gem", facts: [] }))
  end

  def run = described_class.new.call

  it "is off by default and registered with the runner" do
    swap_row

    expect(AppSettings.review_policy_enabled?(:auto_apply_relation_retype)).to be(false)
    expect(ReviewPolicyRunner::POLICIES).to include(described_class)
    expect(run).to include("disabled" => true)
    expect(part_of.reload).to be_present
  end

  it "shows every ownership phrase in its help text" do
    help = I18n.t("system.settings.review_policies.policies.auto_apply_relation_retype")

    described_class::OWNERSHIP_PHRASES.each { |phrase| expect(help).to include(%("#{phrase}")) }
  end

  it "applies a swap with no ownership signal, in a policy change set that Undo reverses" do
    enable!
    fs_observe!(app, "SynthApp uses SynthLib for parsing.")
    row = swap_row

    stats = run

    expect(stats).to include("acted" => 1, "skipped" => 0, "refused" => 0, "busy" => 0)
    expect(library.reload.project_id).to be_nil
    expect(MemoryRelation.exists?(from_entity_id: app.id, to_entity_id: library.id, relation_type: "depends_on")).to be(true)
    expect(row.reload.status).to eq("approved")
    set = ChangeSet.find_by!(uuid: stats["change_sets"].sole)
    expect(set.kind).to eq("policy.auto_apply_relation_retype")
    expect(set.audit_logs.pluck(:actor).uniq).to eq([ "policy:auto_apply_relation_retype" ])

    expect(ChangeSetUndo.call(set.uuid, actor: "operator:synth@127.0.0.1")).to be_ok
    expect(library.reload.project_id).to eq(app.id)
  end

  it "leaves a swap for the operator when a fact of the project names the library with an ownership phrase" do
    enable!
    ReviewPolicies::AutoApplyRelationRetype::OWNERSHIP_PHRASES.each do |phrase|
      fact = fs_observe!(app, "SynthLib is #{phrase} code.")
      row = swap_row

      expect(run).to include("acted" => 0, "skipped" => 1), phrase
      expect(library.reload.project_id).to eq(app.id)
      expect(row.reload.status).to eq("active")
      fact.destroy!
      row.destroy!
    end
  end

  it "leaves a swap for the operator when its entity is no longer of a dependency-like type" do
    enable!
    row = swap_row
    AppSettings.dependency_like_types = "Tool"

    expect(run).to include("acted" => 0, "skipped" => 1)
    expect(row.reload.status).to eq("active")
    expect(library.reload.project_id).to eq(app.id)
  end

  it "reads the signal from facts held by the library and from keyword paths, not from facts naming something else" do
    enable!
    other = fs_member!(app, "SynthOther", "Component")
    fs_observe!(other, "SynthOther is vendored.") # names another entity: no signal for SynthLib
    held = fs_observe!(library, "Forked from upstream in 2026.")

    expect(described_class.ownership_signal?(library, app)).to be(true)
    held.destroy!
    expect(described_class.ownership_signal?(library, app)).to be(false)

    by_path = fs_observe!(other, "The parser is maintained here.")
    by_path.update_columns(keywords: [ "SynthApp", "SynthOther", "SynthLib" ], keywords_at: Time.current)
    expect(described_class.ownership_signal?(library, app)).to be(true)
  end

  it "never applies a retype or an add row" do
    enable!
    variant = MemoryRelation.create!(from_entity: MemoryEntity.create!(name: "SynthWidget", entity_type: "Component"),
                                     to_entity: app, relation_type: "synth_placeholder")
    variant.update_column(:relation_type, "child_of")
    RelationTypeSweep.call
    orphan = MemoryEntity.create!(name: "SynthTool", entity_type: "Tool")
    seed(CompactionReviewApplier::RelationRetypeDependency.add_item(app, orphan, evidence: { entity_type: "Tool" }))

    expect(run).to include("acted" => 0)
    expect(MaintenanceReportRow.where(kind: "relation_retype").pluck(:status)).to eq(%w[active active])
    expect(variant.reload.relation_type).to eq("child_of")
    expect(MemoryRelation.exists?(from_entity_id: app.id, to_entity_id: orphan.id)).to be(false)
  end

  it "refuses a retype or add row handed to it, row by row" do
    enable!
    orphan = MemoryEntity.create!(name: "SynthTool", entity_type: "Tool")
    add = seed(CompactionReviewApplier::RelationRetypeDependency.add_item(app, orphan, evidence: { entity_type: "Tool" }))
    policy = described_class.new
    allow(policy).to receive(:candidates).and_return([ add ])

    expect(policy.call).to include("acted" => 0, "refused" => 1)
    expect(add.reload.status).to eq("active")
  end

  it "skips a swap the global scope refuses (name taken), and counts a busy lock and ends the step" do
    enable!
    MemoryEntity.create!(name: "SynthLib", entity_type: "Gem")
    swap_row

    expect(run).to include("acted" => 0, "skipped" => 1)
    expect(MaintenanceReportRow.where(kind: "entity_merge").count).to eq(1)
  end

  it "counts a busy membership lock as busy and stops the step" do
    enable!
    second = fs_member!(app, "SynthGem", "Gem")
    swap_row
    swap_row(MemoryRelation.find_by!(from_entity_id: second.id, relation_type: "part_of"))
    stub_const("ProjectMembership::LOCK_TIMEOUT_SECONDS", 0)
    conn = ActiveRecord::Base.connection
    name = ProjectMembership.lock_name(conn)
    holder = stub_const("RelationRetypePolicyLockHolder", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    holder.establish_connection(ActiveRecord::Base.connection_db_config)
    holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(name)}, 5)")

    expect(run).to include("acted" => 0, "busy" => 1)
    expect([ library, second ].map { |entity| entity.reload.project_id }).to eq([ app.id, app.id ])
  ensure
    holder.connection.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})") if holder&.connection
    holder.connection_pool&.disconnect! if holder
  end
end
