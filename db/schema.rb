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

ActiveRecord::Schema.define(version: 20160805005250) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "batches", force: true do |t|
    t.string   "text"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "flash_cards", force: true do |t|
    t.integer  "batch_id"
    t.string   "title"
    t.text     "body"
    t.integer  "pin"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "lines", force: true do |t|
    t.integer  "flash_card_id"
    t.string   "text"
    t.boolean  "center"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "litter_text_reminders", force: true do |t|
    t.integer  "turn",       default: 0
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "pokemons", force: true do |t|
    t.integer  "pokedex_id"
    t.string   "lat"
    t.string   "lng"
    t.string   "name"
    t.datetime "expires_at"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "pokewalkers", force: true do |t|
    t.string   "username"
    t.string   "password"
    t.string   "last_loc"
    t.boolean  "banned",            default: false
    t.string   "monitor_loc_start"
    t.string   "monitor_loc_end"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "venmos", force: true do |t|
    t.string   "access_code"
    t.string   "access_token"
    t.string   "refresh_token"
    t.datetime "expires_at"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

end
