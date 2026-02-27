# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_02_27_122156) do
  create_table "entity_type_mappings", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "canonical_type", null: false
    t.string "variant", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["canonical_type"], name: "index_entity_type_mappings_on_canonical_type"
    t.index ["variant"], name: "index_entity_type_mappings_on_variant", unique: true
  end

# Could not dump table "memory_entities" because of following StandardError
#   Unknown type 'vector(768)' for column 'embedding'


# Could not dump table "memory_observations" because of following StandardError
#   Unknown type 'vector(768)' for column 'embedding'


  create_table "memory_relations", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "from_entity_id", null: false
    t.bigint "to_entity_id", null: false
    t.string "relation_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_entity_id", "to_entity_id", "relation_type"], name: "index_memory_relations_uniqueness", unique: true
    t.index ["from_entity_id"], name: "index_memory_relations_on_from_entity_id"
    t.index ["relation_type"], name: "index_memory_relations_on_relation_type"
    t.index ["to_entity_id"], name: "index_memory_relations_on_to_entity_id"
  end

  add_foreign_key "memory_observations", "memory_entities"
  add_foreign_key "memory_relations", "memory_entities", column: "from_entity_id"
  add_foreign_key "memory_relations", "memory_entities", column: "to_entity_id"
end
