# encoding: UTF-8
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

ActiveRecord::Schema.define(version: 20141127033307) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "activities", force: true do |t|
    t.integer  "trackable_id"
    t.string   "trackable_type"
    t.integer  "owner_id"
    t.string   "owner_type"
    t.string   "key"
    t.text     "parameters"
    t.integer  "recipient_id"
    t.string   "recipient_type"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  add_index "activities", ["owner_id", "owner_type"], name: "index_activities_on_owner_id_and_owner_type", using: :btree
  add_index "activities", ["recipient_id", "recipient_type"], name: "index_activities_on_recipient_id_and_recipient_type", using: :btree
  add_index "activities", ["trackable_id", "trackable_type"], name: "index_activities_on_trackable_id_and_trackable_type", using: :btree

  create_table "flash_cards", force: true do |t|
    t.string   "title"
    t.string   "line"
    t.text     "body",       default: [["", "0"], ["", "0"], ["", "0"], ["", "0"], ["", "0"], ["", "0"], ["", "0"]], array: true
    t.integer  "pin"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "follows", force: true do |t|
    t.integer  "followable_id",                   null: false
    t.string   "followable_type",                 null: false
    t.integer  "follower_id",                     null: false
    t.string   "follower_type",                   null: false
    t.boolean  "blocked",         default: false, null: false
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  add_index "follows", ["followable_id", "followable_type"], name: "fk_followables", using: :btree
  add_index "follows", ["follower_id", "follower_type"], name: "fk_follows", using: :btree

  create_table "games", force: true do |t|
    t.string   "name"
    t.string   "ava"
    t.string   "play"
    t.text     "about"
    t.text     "howto"
    t.integer  "cost"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string   "thumb"
  end

  create_table "notifications", force: true do |t|
    t.integer  "notify_id"
    t.integer  "game_id"
    t.integer  "user_id"
    t.string   "message"
    t.boolean  "isRead",     default: false
    t.integer  "gold"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string   "title"
    t.integer  "icon"
    t.integer  "sent_id"
  end

  create_table "pg_search_documents", force: true do |t|
    t.text     "content"
    t.integer  "searchable_id"
    t.string   "searchable_type"
    t.datetime "created_at",      null: false
    t.datetime "updated_at",      null: false
  end

  create_table "shouts", force: true do |t|
    t.integer  "user_id"
    t.integer  "sent_from_id"
    t.string   "message"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.integer  "game_id"
  end

  create_table "trophies", force: true do |t|
    t.integer  "user_id"
    t.integer  "game_id"
    t.integer  "uniq_id"
    t.boolean  "seen",       default: false
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "user_game_logs", force: true do |t|
    t.integer  "user_id"
    t.integer  "game_id"
    t.integer  "score"
    t.string   "event",      default: "played"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "user_game_statistics", force: true do |t|
    t.integer  "user_id"
    t.integer  "game_id"
    t.integer  "count",      default: 0
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "users", force: true do |t|
    t.string   "name"
    t.text     "about"
    t.integer  "coin",                   default: 0
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string   "email",                  default: "",           null: false
    t.string   "encrypted_password",     default: "",           null: false
    t.string   "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer  "sign_in_count",          default: 0,            null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.inet     "current_sign_in_ip"
    t.inet     "last_sign_in_ip"
    t.string   "username"
    t.string   "avatar_file_name"
    t.string   "avatar_content_type"
    t.integer  "avatar_file_size"
    t.datetime "avatar_updated_at"
    t.integer  "coinTo",                 default: 20
    t.integer  "favorites",              default: [0, 0, 0, 0],              array: true
    t.integer  "popup",                  default: [],                        array: true
    t.string   "facebook_url",           default: ""
    t.string   "twitter_url",            default: ""
    t.string   "website_url",            default: ""
    t.string   "ava"
    t.datetime "last_in"
  end

  add_index "users", ["email"], name: "index_users_on_email", unique: true, using: :btree
  add_index "users", ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true, using: :btree
  add_index "users", ["username"], name: "index_users_on_username", unique: true, using: :btree

end
