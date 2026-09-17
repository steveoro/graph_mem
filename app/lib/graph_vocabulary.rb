# frozen_string_literal: true

module GraphVocabulary
  ENTITY_TYPE_MAPPINGS = {
    "Project" => %w[project projects workspace workspaces context repo repository codebase],
    "Framework" => %w[framework frameworks lib library],
    "ApplicationStack" => %w[applicationstack application_stack app_stack stack techstack tech_stack],
    "Workflow" => %w[workflow workflows process],
    "BestPractice" => %w[bestpractice best_practice practice guideline convention pattern],
    "Task" => %w[task tasks todo],
    "Step" => %w[step steps substep sub_step],
    "Issue" => %w[issue issues bug problem],
    "Error" => %w[error errors exception],
    "PossibleSolution" => %w[possiblesolution possible_solution solution workaround fix],
    "Model" => %w[model models activerecord_model],
    "DatabaseTable" => %w[databasetable database_table table db_table],
    "DatabaseSchema" => %w[databaseschema database_schema schema db_schema],
    "Class" => %w[class classes module],
    "APIEndpoint" => %w[apiendpoint api_endpoint endpoint api],
    "Route" => %w[route routes],
    "Component" => %w[component components widget],
    "Service" => %w[service services],
    "Configuration" => %w[configuration config setting settings],
    "Migration" => %w[migration migrations db_migration],
    "TestCase" => %w[testcase test_case test spec],
    "Permission" => %w[permission permissions role],
    "User" => %w[user users person],
    "Preference" => %w[preference preferences pref],
    "Constant" => %w[constant constants const],
    "ProjectPlan" => %w[projectplan project_plan plan],
    "Feature" => %w[feature features],
    "Gem" => %w[gem gems rubygem],
    "Tool" => %w[tool tools],
    "Resource" => %w[resource resources],
    "Documentation" => %w[documentation docs doc readme]
  }.freeze
  RELATION_TYPE_MAPPINGS = {
    "part_of" => %w[partof belongs_to child_of contained_in],
    "depends_on" => %w[dependson requires prerequisite_of],
    "relates_to" => %w[related_to relatedto associated_with connected_to connects_to],
    "implements" => %w[implementation_of provides],
    "solves" => %w[resolves fixes solution_for]
  }.freeze
  EXTRA_RELATION_TYPES = %w[
    extends configured_by tested_by migrated_by authorizes integrates_with replaces
  ].freeze
  ENTITY_TYPES = ENTITY_TYPE_MAPPINGS.keys.freeze
  RELATION_TYPES = (RELATION_TYPE_MAPPINGS.keys + EXTRA_RELATION_TYPES).freeze

  module_function

  # Suggests a close canonical type without rejecting novel values.
  #
  # @param value [String, nil] submitted type
  # @param examples [Array<String>] canonical vocabulary
  # @return [Hash, nil] submitted/suggested type hint
  def suggestion(value, examples)
    return if value.blank? || examples.any? { |example| example.casecmp?(value.to_s) }

    suggested = DidYouMean::SpellChecker.new(dictionary: examples).correct(value.to_s).first
    return unless suggested

    { submitted: value.to_s, suggested: suggested }
  end
end
