# frozen_string_literal: true

require "rails_helper"

# 1.82.0: the ladder from "related" to "the same fact". Only the same subject may make one fact
# obsolete; a related one only ever reaches the judge. Paths are [project, own entity, mentions…].
RSpec.describe FactKeywords::Relatedness, "the same-fact ladder" do
  def ladder(first_path, first_text, second_path, second_text)
    described_class.compare_paths(first_path, first_path[1] || first_path[0], second_path, second_path[1] || second_path[0],
                                  first_text: first_text, second_text: second_text)
  end

  # first path, first text, second path, second text => same_subject, covers, details, level, same fact with a different detail
  ROWS = {
    "Rails 8.0 → 8.1, Rails an entity" =>
      [ %w[p App Rails], "Updated using Rails 8.1", %w[p App Rails], "Developed using Rails 8.0", true, :both, :different, "same", true ],
    "Rails 8.0 → 8.1, no mentions (F2c's case)" =>
      [ %w[p App], "Updated using Rails 8.1", %w[p App], "Developed using Rails 8.0", false, nil, :different, "unclear", false ],
    "belongs to vs validates a User (same subject, no detail)" =>
      [ %w[p AdminGrant User], "It validates the User's email.", %w[p AdminGrant User], "It belongs to a User.", true, :both, :none, "same", false ],
    "cross-owned: AdminGrant ↔ User" =>
      [ %w[p AdminGrant User], "At most 5 grants per User.", %w[p User AdminGrant], "A User holds at most 3 AdminGrants.", true, :both, :different, "same", true ],
    "the fact covers more than the old one" =>
      [ %w[p App User Team], "Release 2 adds Teams to Users.", %w[p App User], "Release 1 has Users.", true, :first, :different, "same", true ],
    "the old one covers more than the fact" =>
      [ %w[p App User], "Release 2 has Users.", %w[p App User Team], "Release 1 has Users and Teams.", true, :second, :different, "same", false ],
    "siblings the paths don't connect" =>
      [ %w[p Rework], "Approve the read tools first.", %w[p ServerRules], "Never pass the dev database.", false, nil, :none, "unclear", false ],
    "related: a shared mention, neither covers the other" =>
      [ %w[p A B C], "B feeds C.", %w[p A B D], "B feeds D.", false, nil, :none, "related", false ],
    "one-sided" =>
      [ %w[p A User], "It belongs to a User.", %w[p A], "It is a model.", false, nil, :none, "unclear", false ],
    "an incidental id counts as a detail (documented)" =>
      [ %w[p A Ticket], "Fixed in #4230 for the Ticket.", %w[p A Ticket], "Fixed in #4227 for the Ticket.", true, :both, :different, "same", true ],
    "the same detail: a rewording" =>
      [ %w[p App Puma], "Puma listens on 3030.", %w[p App Puma], "Puma runs on port 3030.", true, :both, :same, "same", false ],
    "a different date" =>
      [ %w[p A Backup], "Backups since 2026-11-13.", %w[p A Backup], "Backups since 2026-11-12.", true, :both, :different, "same", true ],
    "a different unit value" =>
      [ %w[p A Ollama], "Ollama times out after 10s.", %w[p A Ollama], "Ollama times out after 5s.", true, :both, :different, "same", true ],
    "8.0 is not 8" =>
      [ %w[p App Rails], "Rails 8.", %w[p App Rails], "Rails 8.0.", true, :both, :different, "same", true ],
    "both mention entities, none shared" =>
      [ %w[p A User], "It belongs to a User.", %w[p A Team], "It names a Team.", false, nil, :none, "unclear", false ],
    "a fact on the project root itself" =>
      [ %w[p], "Use Ruby 3.4.", %w[p A User], "Users need Ruby 3.3.", false, nil, :different, "unclear", false ],
    "the mentions in another order" =>
      [ %w[p A User Team], "Teams of Users, v2.", %w[p A Team User], "Users in Teams, v1.", true, :both, :different, "same", true ],
    "the same versions in another order" =>
      [ %w[p App Ruby Rails], "Rails 8.1 with Ruby 3.4.12.", %w[p App Ruby Rails], "Ruby 3.4.12 and Rails 8.1.", true, :both, :same, "same", false ],
    "a version added" =>
      [ %w[p App Rails], "Uses Rails 8.1.", %w[p App Rails], "Uses Rails.", true, :both, :different, "same", true ],
    "a vaguer restatement drops the detail: never a different detail (Graphy)" =>
      [ %w[p App Rails], "Uses Rails.", %w[p App Rails], "Uses Rails 8.1.", true, :both, :dropped, "same", false ],
    "related through a mentioned own entity, not covering" =>
      [ %w[p Badge Swimmer Season], "A Swimmer has one Badge per Season.", %w[p Swimmer Team], "A Swimmer joins one Team.", false, nil, :none, "related", false ]
  }.freeze

  ROWS.each do |name, (first_path, first_text, second_path, second_text, same, covers, details, level, same_fact)|
    it name do
      result = ladder(first_path, first_text, second_path, second_text)

      expect(result).to have_attributes(same_subject: same, covers: covers, details: details, level: level)
      expect(result.same_fact_different_detail?).to be(same_fact)
    end
  end

  # A fact held by the project root is about the whole project (its path is [project, mentions…]):
  # it covers a member's own entity (final review of 1.82.0).
  it "lets a project-level fact cover a member's fact about the same thing" do
    result = described_class.compare_paths(%w[p Rails], "p", %w[p App Rails], "App",
                                           first_text: "The project uses Rails 8.1.", second_text: "SynthApp is developed using Rails 8.0.")

    expect(result).to have_attributes(same_subject: true, covers: :first, details: :different, level: "same")
    expect(result.same_fact_different_detail?).to be(true)
  end

  it "never lets a member's fact cover a project-level one" do
    result = described_class.compare_paths(%w[p App Rails], "App", %w[p Rails], "p",
                                           first_text: "SynthApp uses Rails 8.1.", second_text: "The project runs Rails 8.0.")

    expect(result).to have_attributes(same_subject: true, covers: :second)
    expect(result.same_fact_different_detail?).to be(false)
  end

  it "treats a fact on an entity with no project as that entity's, not as the project's (Graphy)" do
    root = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
    app = MemoryEntity.create!(name: "SynthApp", entity_type: "Component", project_id: root.id)
    loose = MemoryEntity.create!(name: "LooseNotes", entity_type: "Note")
    member = MemoryObservation.create!(memory_entity: app, content: "SynthApp runs on Puma 6.")
    member.update_columns(keywords: [ "Gadget Project", "SynthApp", "Puma" ], keywords_at: Time.current)
    unscoped = MemoryObservation.create!(memory_entity: loose, content: "Puma 5 serves Rails.")
    unscoped.update_columns(keywords: [ "LooseNotes", "Puma", "Rails" ], keywords_at: Time.current)

    # Its path starts with its own entity, like a project root's, but it isn't about the whole project.
    expect(described_class.compare(member, unscoped)).to have_attributes(same_subject: false, covers: nil, level: "related")
  end

  # 1.83.0: two facts on one entity that name no entity compare by their LLM words.
  def words(first_text, first_words, second_text, second_words, first_path: %w[p App], second_path: %w[p App])
    described_class.compare_paths(first_path, first_path[1], second_path, second_path[1], first_text: first_text, second_text: second_text,
                                  first_words: first_words, second_words: second_words)
  end

  it "makes Rails 8.0 → 8.1 with no mentions the same fact with a different detail, by their words" do
    result = words("Updated using Rails 8.1", %w[rails version], "Developed using Rails 8.0", %w[rails version])

    expect(result).to have_attributes(subject: :related, same_subject: true, covers: :both, details: :different, level: "same")
    expect(result.same_fact_different_detail?).to be(true)
  end

  it "folds case and plurals when comparing words" do
    expect(words("A", %w[versions Rails], "B", %w[rails version])).to have_attributes(same_subject: true, covers: :both)
  end

  it "relates facts sharing some words, and calls facts sharing none unrelated (full weight)" do
    expect(words("Validates presence of email", %w[email presence], "Validates presence of name", %w[name presence]))
      .to have_attributes(subject: :related, same_subject: false, covers: nil, level: "related")
    expect(words("Hashes passwords with bcrypt", %w[bcrypt password], "Validates presence of name", %w[name presence]))
      .to have_attributes(subject: :unrelated, same_subject: false)
  end

  it "knows which fact's words cover the other's" do
    expect(words("Validates presence", %w[presence], "Validates presence of email", %w[email presence])).to have_attributes(covers: :second)
    expect(words("Validates presence of email", %w[email presence], "Validates presence", %w[presence])).to have_attributes(covers: :first)
  end

  it "stays unclear while one side's words are missing or empty" do
    expect(words("A", %w[name], "B", nil)).to have_attributes(subject: :unknown, level: "unclear")
    expect(words("A", %w[name], "B", [])).to have_attributes(subject: :unknown, level: "unclear")
  end

  it "ignores words once a fact mentions an entity, and across two entities" do
    mention = words("It belongs to a User.", %w[user], "Names a user.", %w[user], first_path: %w[p App User])
    expect(mention).to have_attributes(subject: :one_sided, same_subject: false)
    siblings = words("A", %w[name], "B", %w[name], second_path: %w[p Other])
    expect(siblings).to have_attributes(subject: :unrelated, same_subject: false)
  end

  it "passes the stored words of computed facts, and none with LLM keywords off" do
    root = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
    app = MemoryEntity.create!(name: "SynthApp", entity_type: "Component", project_id: root.id)
    old, new = [ "Developed using Rails 8.0", "Updated using Rails 8.1" ].map do |content|
      MemoryObservation.create!(memory_entity: app, content: content).tap do |fact|
        fact.update_columns(keywords: [ "Gadget Project", "SynthApp" ], keywords_at: Time.current,
                            llm_keywords: %w[rails version], llm_keywords_at: Time.current)
      end
    end

    expect(described_class.compare(new, old).same_fact_different_detail?).to be(true)
    AppSettings.llm_keywords_enabled = false
    expect(described_class.compare(new, old).subject).to eq(:unknown)
  ensure
    AppSettings.where(var: "llm_keywords_enabled").delete_all
  end

  it "reads the details from the facts themselves when comparing observations" do
    root = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
    app = MemoryEntity.create!(name: "SynthApp", entity_type: "Component", project_id: root.id)
    old, new = [ "Developed using Rails 8.0", "Updated using Rails 8.1" ].map do |content|
      MemoryObservation.create!(memory_entity: app, content: content).tap do |fact|
        fact.update_columns(keywords: [ "Gadget Project", "SynthApp", "Rails" ], keywords_at: Time.current)
      end
    end

    expect(described_class.compare(new, old)).to have_attributes(same_subject: true, covers: :both, details: :different)
  end
end
