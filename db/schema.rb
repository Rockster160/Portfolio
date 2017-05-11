# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 20170511003751) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "batches", force: :cascade do |t|
    t.string   "text",       limit: 255
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "flash_cards", force: :cascade do |t|
    t.integer  "batch_id"
    t.string   "title",      limit: 255
    t.text     "body"
    t.integer  "pin"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "lines", force: :cascade do |t|
    t.integer  "flash_card_id"
    t.string   "text",          limit: 255
    t.boolean  "center"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "list_items", force: :cascade do |t|
    t.string   "name",       limit: 255
    t.integer  "list_id"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.integer  "sort_order"
    t.index ["list_id"], name: "index_list_items_on_list_id", using: :btree
  end

  create_table "lists", force: :cascade do |t|
    t.string   "name",        limit: 255
    t.datetime "created_at"
    t.datetime "updated_at"
    t.text     "description"
  end

  create_table "litter_text_reminders", force: :cascade do |t|
    t.integer  "turn",                   default: 0
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string   "regex",      limit: 255
    t.string   "message",    limit: 255
  end

  create_table "monster_skills", force: :cascade do |t|
    t.integer "monster_id"
    t.string  "name"
    t.text    "description"
    t.string  "stat"
    t.index ["monster_id"], name: "index_monster_skills_on_monster_id", using: :btree
  end

  create_table "monsters", force: :cascade do |t|
    t.string  "name"
    t.string  "url"
    t.integer "element"
    t.integer "health"
    t.integer "attack"
    t.integer "defense"
    t.integer "speed"
    t.integer "crit_rate"
    t.integer "crit_damage"
    t.integer "resistance"
    t.integer "accuracy"
  end

  create_table "user_lists", force: :cascade do |t|
    t.integer "user_id"
    t.integer "list_id"
    t.boolean "is_owner"
    t.index ["list_id"], name: "index_user_lists_on_list_id", using: :btree
    t.index ["user_id"], name: "index_user_lists_on_user_id", using: :btree
  end

  create_table "users", force: :cascade do |t|
    t.string   "username"
    t.string   "password_digest"
    t.datetime "created_at",       null: false
    t.datetime "updated_at",       null: false
    t.string   "phone"
    t.string   "invitation_token"
  end

  create_table "venmos", force: :cascade do |t|
    t.string   "access_code",   limit: 255
    t.string   "access_token",  limit: 255
    t.string   "refresh_token", limit: 255
    t.datetime "expires_at"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

end
