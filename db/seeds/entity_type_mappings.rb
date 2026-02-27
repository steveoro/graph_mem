# frozen_string_literal: true

# Canonical entity types and their known variants.
# The first entry in each list is the canonical form.
CANONICAL_TYPES = {
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

puts "Seeding entity type mappings..."
count = 0

CANONICAL_TYPES.each do |canonical, variants|
  # The canonical type itself is also a variant (for exact matches)
  ([ canonical ] + variants).uniq(&:downcase).each do |variant|
    EntityTypeMapping.find_or_create_by!(variant: variant.downcase) do |m|
      m.canonical_type = canonical
    end
    count += 1
  end
end

puts "Seeded #{count} entity type mappings."
