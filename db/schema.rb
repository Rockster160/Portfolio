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

ActiveRecord::Schema.define(version: 20211118063000) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "action_events", force: :cascade do |t|
    t.text     "event_name"
    t.integer  "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "timestamp"
    t.text     "notes"
    t.index ["user_id"], name: "index_action_events_on_user_id", using: :btree
  end

  create_table "avatar_clothes", force: :cascade do |t|
    t.integer  "avatar_id"
    t.string   "gender"
    t.string   "placement"
    t.string   "garment"
    t.string   "color"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["avatar_id"], name: "index_avatar_clothes_on_avatar_id", using: :btree
  end

  create_table "avatars", force: :cascade do |t|
    t.integer  "user_id"
    t.datetime "created_at",   null: false
    t.datetime "updated_at",   null: false
    t.integer  "location_x"
    t.integer  "location_y"
    t.string   "timestamp"
    t.integer  "uuid",         null: false
    t.boolean  "from_session"
    t.index ["user_id"], name: "index_avatars_on_user_id", using: :btree
  end

  create_table "batches", force: :cascade do |t|
    t.string   "text",       limit: 255
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "bowlers", force: :cascade do |t|
    t.integer  "league_id"
    t.integer  "position"
    t.text     "name"
    t.integer  "total_points"
    t.integer  "total_games"
    t.datetime "created_at",   null: false
    t.datetime "updated_at",   null: false
    t.index ["league_id"], name: "index_bowlers_on_league_id", using: :btree
  end

  create_table "bowling_games", force: :cascade do |t|
    t.integer  "bowler_id"
    t.integer  "set_id"
    t.integer  "position"
    t.integer  "game_num"
    t.integer  "score"
    t.text     "frames"
    t.boolean  "card_point", default: false
    t.datetime "created_at",                 null: false
    t.datetime "updated_at",                 null: false
    t.index ["bowler_id"], name: "index_bowling_games_on_bowler_id", using: :btree
    t.index ["set_id"], name: "index_bowling_games_on_set_id", using: :btree
  end

  create_table "bowling_leagues", force: :cascade do |t|
    t.integer  "user_id"
    t.text     "name"
    t.text     "team_name"
    t.text     "handicap_calculation", default: "0"
    t.integer  "games_per_series",     default: 3
    t.datetime "created_at",                         null: false
    t.datetime "updated_at",                         null: false
    t.index ["user_id"], name: "index_bowling_leagues_on_user_id", using: :btree
  end

  create_table "bowling_sets", force: :cascade do |t|
    t.integer  "league_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["league_id"], name: "index_bowling_sets_on_league_id", using: :btree
  end

  create_table "command_proposal_comments", force: :cascade do |t|
    t.integer  "iteration_id"
    t.integer  "line_number"
    t.integer  "author_id"
    t.text     "body"
    t.datetime "created_at",   null: false
    t.datetime "updated_at",   null: false
    t.index ["author_id"], name: "index_command_proposal_comments_on_author_id", using: :btree
    t.index ["iteration_id"], name: "index_command_proposal_comments_on_iteration_id", using: :btree
  end

  create_table "command_proposal_iterations", force: :cascade do |t|
    t.integer  "task_id"
    t.text     "args"
    t.text     "code"
    t.text     "result"
    t.integer  "status",       default: 0
    t.integer  "requester_id"
    t.integer  "approver_id"
    t.datetime "approved_at"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "stopped_at"
    t.datetime "created_at",               null: false
    t.datetime "updated_at",               null: false
    t.index ["approver_id"], name: "index_command_proposal_iterations_on_approver_id", using: :btree
    t.index ["requester_id"], name: "index_command_proposal_iterations_on_requester_id", using: :btree
    t.index ["task_id"], name: "index_command_proposal_iterations_on_task_id", using: :btree
  end

  create_table "command_proposal_tasks", force: :cascade do |t|
    t.text     "name"
    t.text     "friendly_id"
    t.text     "description"
    t.integer  "session_type",     default: 0
    t.datetime "last_executed_at"
    t.datetime "created_at",                   null: false
    t.datetime "updated_at",                   null: false
  end

  create_table "companies", force: :cascade do |t|
    t.integer  "user_id"
    t.string   "name"
    t.string   "recruiter"
    t.string   "url"
    t.integer  "status"
    t.text     "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_companies_on_user_id", using: :btree
  end

  create_table "emails", force: :cascade do |t|
    t.integer  "sent_by_id"
    t.string   "from"
    t.string   "to"
    t.string   "subject"
    t.text     "blob"
    t.text     "text_body"
    t.text     "html_body"
    t.datetime "read_at"
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sent_by_id"], name: "index_emails_on_sent_by_id", using: :btree
  end

  create_table "flash_cards", force: :cascade do |t|
    t.integer  "batch_id"
    t.string   "title",      limit: 255
    t.text     "body"
    t.integer  "pin"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "functions", force: :cascade do |t|
    t.text     "title"
    t.text     "arguments"
    t.text     "description"
    t.datetime "deploy_begin_at"
    t.datetime "deploy_finish_at"
    t.text     "proposed_code"
    t.text     "results"
    t.datetime "created_at",       null: false
    t.datetime "updated_at",       null: false
  end

  create_table "interviews", force: :cascade do |t|
    t.integer  "company_id"
    t.datetime "start_time"
    t.text     "participants"
    t.text     "notes"
    t.datetime "created_at",   null: false
    t.datetime "updated_at",   null: false
    t.index ["company_id"], name: "index_interviews_on_company_id", using: :btree
  end

  create_table "lines", force: :cascade do |t|
    t.integer  "flash_card_id"
    t.string   "text",          limit: 255
    t.boolean  "center"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "list_items", force: :cascade do |t|
    t.text     "name"
    t.integer  "list_id"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.integer  "sort_order"
    t.text     "formatted_name"
    t.datetime "deleted_at"
    t.boolean  "important",      default: false
    t.boolean  "permanent",      default: false
    t.string   "schedule"
    t.string   "category"
    t.datetime "schedule_next"
    t.integer  "timezone"
    t.integer  "amount"
    t.index ["deleted_at"], name: "index_list_items_on_deleted_at", using: :btree
    t.index ["list_id"], name: "index_list_items_on_list_id", using: :btree
  end

  create_table "lists", force: :cascade do |t|
    t.string   "name",         limit: 255
    t.datetime "created_at"
    t.datetime "updated_at"
    t.text     "description"
    t.boolean  "important",                default: false
    t.boolean  "show_deleted"
  end

  create_table "litter_text_reminders", force: :cascade do |t|
    t.integer  "turn",                   default: 0
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string   "regex",      limit: 255
    t.string   "message",    limit: 255
  end

  create_table "locations", force: :cascade do |t|
    t.string "ip"
    t.string "country_code"
    t.string "country_name"
    t.string "region_code"
    t.string "region_name"
    t.string "city"
    t.string "zip_code"
    t.string "time_zone"
    t.float  "latitude"
    t.float  "longitude"
    t.string "metro_code"
  end

  create_table "log_trackers", force: :cascade do |t|
    t.string   "user_agent"
    t.string   "ip_address"
    t.string   "http_method"
    t.string   "url"
    t.string   "params"
    t.integer  "user_id"
    t.datetime "created_at",  null: false
    t.datetime "updated_at",  null: false
    t.integer  "ip_count"
    t.integer  "location_id"
    t.text     "headers"
    t.text     "body"
    t.index ["location_id"], name: "index_log_trackers_on_location_id", using: :btree
    t.index ["user_id"], name: "index_log_trackers_on_user_id", using: :btree
  end

  create_table "money_buckets", force: :cascade do |t|
    t.integer "user_id"
    t.text    "bucket_json"
    t.index ["user_id"], name: "index_money_buckets_on_user_id", using: :btree
  end

  create_table "monster_skills", force: :cascade do |t|
    t.integer  "monster_id"
    t.string   "name"
    t.text     "description"
    t.string   "muliplier_formula"
    t.integer  "sort_order"
    t.datetime "created_at",        null: false
    t.datetime "updated_at",        null: false
    t.index ["monster_id"], name: "index_monster_skills_on_monster_id", using: :btree
  end

  create_table "monsters", force: :cascade do |t|
    t.string   "name"
    t.string   "url"
    t.string   "image_url"
    t.integer  "stars"
    t.integer  "element"
    t.integer  "archetype"
    t.integer  "health"
    t.integer  "attack"
    t.integer  "defense"
    t.integer  "speed"
    t.integer  "crit_rate"
    t.integer  "crit_damage"
    t.integer  "resistance"
    t.integer  "accuracy"
    t.datetime "last_updated"
    t.datetime "created_at",   null: false
    t.datetime "updated_at",   null: false
  end

  create_table "payment_categories", force: :cascade do |t|
    t.integer "user_id"
    t.string  "name"
    t.index ["user_id"], name: "index_payment_categories_on_user_id", using: :btree
  end

  create_table "payment_charges", force: :cascade do |t|
    t.integer  "user_id"
    t.integer  "payment_category_id"
    t.integer  "payment_group_id"
    t.text     "raw"
    t.string   "amount_in_pennies"
    t.datetime "occurred_at"
    t.datetime "created_at",          null: false
    t.datetime "updated_at",          null: false
    t.index ["payment_category_id"], name: "index_payment_charges_on_payment_category_id", using: :btree
    t.index ["payment_group_id"], name: "index_payment_charges_on_payment_group_id", using: :btree
    t.index ["user_id"], name: "index_payment_charges_on_user_id", using: :btree
  end

  create_table "payment_groups", force: :cascade do |t|
  end

  create_table "payment_schedules", force: :cascade do |t|
    t.integer  "user_id"
    t.string   "name"
    t.string   "description"
    t.integer  "amount_in_pennies"
    t.datetime "recurrence_start"
    t.integer  "recurrence_date"
    t.integer  "recurrence_wday"
    t.integer  "recurrence_type"
    t.datetime "created_at",        null: false
    t.datetime "updated_at",        null: false
    t.index ["user_id"], name: "index_payment_schedules_on_user_id", using: :btree
  end

  create_table "plaid_items", force: :cascade do |t|
    t.integer  "user_id"
    t.string   "bank_name"
    t.text     "plaid_item_id"
    t.text     "plaid_item_access_token"
    t.datetime "created_at",              null: false
    t.datetime "updated_at",              null: false
    t.index ["user_id"], name: "index_plaid_items_on_user_id", using: :btree
  end

  create_table "recipe_favorites", force: :cascade do |t|
    t.integer  "recipe_id"
    t.integer  "favorited_by_id"
    t.datetime "created_at",      null: false
    t.datetime "updated_at",      null: false
    t.index ["favorited_by_id"], name: "index_recipe_favorites_on_favorited_by_id", using: :btree
    t.index ["recipe_id"], name: "index_recipe_favorites_on_recipe_id", using: :btree
  end

  create_table "recipe_shares", force: :cascade do |t|
    t.integer  "recipe_id"
    t.integer  "shared_to_id"
    t.datetime "created_at",   null: false
    t.datetime "updated_at",   null: false
    t.index ["recipe_id"], name: "index_recipe_shares_on_recipe_id", using: :btree
    t.index ["shared_to_id"], name: "index_recipe_shares_on_shared_to_id", using: :btree
  end

  create_table "recipes", force: :cascade do |t|
    t.integer  "user_id"
    t.string   "title"
    t.string   "kitchen_of"
    t.text     "ingredients"
    t.text     "instructions"
    t.boolean  "public"
    t.datetime "created_at",   null: false
    t.datetime "updated_at",   null: false
    t.text     "description"
    t.string   "friendly_url"
    t.index ["user_id"], name: "index_recipes_on_user_id", using: :btree
  end

  create_table "rlcraft_map_locations", force: :cascade do |t|
    t.integer  "x_coord"
    t.integer  "y_coord"
    t.string   "title"
    t.string   "location_type"
    t.string   "description"
    t.datetime "created_at",    null: false
    t.datetime "updated_at",    null: false
  end

  create_table "user_lists", force: :cascade do |t|
    t.integer "user_id"
    t.integer "list_id"
    t.boolean "is_owner"
    t.integer "sort_order"
    t.boolean "default",    default: false
    t.index ["list_id"], name: "index_user_lists_on_list_id", using: :btree
    t.index ["user_id"], name: "index_user_lists_on_user_id", using: :btree
  end

  create_table "user_push_subscriptions", force: :cascade do |t|
    t.integer  "user_id"
    t.string   "sub_auth"
    t.string   "endpoint"
    t.string   "p256dh"
    t.string   "auth"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_user_push_subscriptions_on_user_id", using: :btree
  end

  create_table "users", force: :cascade do |t|
    t.string   "username"
    t.string   "password_digest"
    t.datetime "created_at",                   null: false
    t.datetime "updated_at",                   null: false
    t.string   "phone"
    t.string   "invitation_token"
    t.integer  "role",             default: 0
    t.boolean  "dark_mode"
    t.string   "email"
  end

  create_table "venmo_recurrings", force: :cascade do |t|
    t.string   "to",           default: "3852599640"
    t.string   "from"
    t.integer  "amount_cents"
    t.string   "note"
    t.integer  "day_of_month"
    t.integer  "hour_of_day"
    t.boolean  "active",       default: true
    t.datetime "created_at",                          null: false
    t.datetime "updated_at",                          null: false
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
