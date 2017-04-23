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

ActiveRecord::Schema.define(version: 20170422171818) do

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
    t.string   "name",       limit: 255
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "litter_text_reminders", force: :cascade do |t|
    t.integer  "turn",                   default: 0
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string   "regex",      limit: 255
    t.string   "message",    limit: 255
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
