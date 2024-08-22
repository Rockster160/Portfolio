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

ActiveRecord::Schema[7.1].define(version: 2024_08_22_014938) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_stat_statements"
  enable_extension "plpgsql"
  enable_extension "uuid-ossp"

  create_table "action_events", id: :serial, force: :cascade do |t|
    t.text "name"
    t.integer "user_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "timestamp", precision: nil
    t.text "notes"
    t.integer "streak_length"
    t.jsonb "data"
    t.index ["user_id"], name: "index_action_events_on_user_id"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", precision: nil, null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "addresses", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "contact_id"
    t.boolean "primary"
    t.text "icon"
    t.text "label"
    t.text "street"
    t.float "lat"
    t.float "lng"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contact_id"], name: "index_addresses_on_contact_id"
    t.index ["user_id"], name: "index_addresses_on_user_id"
  end

  create_table "api_keys", force: :cascade do |t|
    t.bigint "user_id"
    t.text "name"
    t.text "key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_used_at", precision: nil
    t.boolean "enabled", default: true
    t.index ["user_id"], name: "index_api_keys_on_user_id"
  end

  create_table "avatar_clothes", id: :serial, force: :cascade do |t|
    t.integer "avatar_id"
    t.string "gender"
    t.string "placement"
    t.string "garment"
    t.string "color"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["avatar_id"], name: "index_avatar_clothes_on_avatar_id"
  end

  create_table "avatars", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "location_x"
    t.integer "location_y"
    t.string "timestamp"
    t.integer "uuid", null: false
    t.boolean "from_session"
    t.index ["user_id"], name: "index_avatars_on_user_id"
  end

  create_table "banned_ips", force: :cascade do |t|
    t.inet "ip"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "whitelisted", default: false
  end

  create_table "batches", id: :serial, force: :cascade do |t|
    t.string "text", limit: 255
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
  end

  create_table "bowler_sets", id: :serial, force: :cascade do |t|
    t.integer "bowler_id"
    t.integer "set_id"
    t.integer "handicap"
    t.integer "absent_score"
    t.integer "starting_avg"
    t.integer "ending_avg"
    t.integer "this_avg"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["bowler_id"], name: "index_bowler_sets_on_bowler_id"
    t.index ["set_id"], name: "index_bowler_sets_on_set_id"
  end

  create_table "bowlers", id: :serial, force: :cascade do |t|
    t.integer "league_id"
    t.integer "position"
    t.text "name"
    t.integer "total_pins"
    t.integer "total_games"
    t.integer "total_points"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "high_game"
    t.integer "high_series"
    t.integer "total_pins_offset"
    t.integer "total_games_offset"
    t.string "usbc_number"
    t.string "usbc_full_name"
    t.index ["league_id"], name: "index_bowlers_on_league_id"
  end

  create_table "bowling_frames", id: :serial, force: :cascade do |t|
    t.integer "bowling_game_id"
    t.integer "frame_num"
    t.integer "throw1"
    t.integer "throw2"
    t.integer "throw3"
    t.string "throw1_remaining"
    t.string "throw2_remaining"
    t.string "throw3_remaining"
    t.boolean "spare", default: false
    t.boolean "strike", default: false
    t.boolean "split", default: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "strike_point"
    t.index ["bowling_game_id"], name: "index_bowling_frames_on_bowling_game_id"
  end

  create_table "bowling_games", id: :serial, force: :cascade do |t|
    t.integer "bowler_id"
    t.integer "set_id"
    t.integer "position"
    t.integer "game_num"
    t.integer "score"
    t.integer "handicap"
    t.text "frames"
    t.boolean "card_point", default: false
    t.boolean "game_point", default: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "absent"
    t.jsonb "frame_details"
    t.boolean "completed", default: false
    t.index ["bowler_id"], name: "index_bowling_games_on_bowler_id"
    t.index ["set_id"], name: "index_bowling_games_on_set_id"
  end

  create_table "bowling_leagues", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.text "name"
    t.text "team_name"
    t.integer "games_per_series", default: 3
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.text "absent_calculation", default: "AVG - 10"
    t.integer "team_size", default: 4
    t.integer "hdcp_base", default: 210
    t.float "hdcp_factor", default: 0.95
    t.string "lanetalk_center_uuid"
    t.index ["user_id"], name: "index_bowling_leagues_on_user_id"
  end

  create_table "bowling_sets", id: :serial, force: :cascade do |t|
    t.integer "league_id"
    t.text "winner"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "lane_number"
    t.index ["league_id"], name: "index_bowling_sets_on_league_id"
  end

  create_table "cache_shares", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "jarvis_cache_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["jarvis_cache_id"], name: "index_cache_shares_on_jarvis_cache_id"
    t.index ["user_id"], name: "index_cache_shares_on_user_id"
  end

  create_table "climbs", force: :cascade do |t|
    t.bigint "user_id"
    t.text "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "timestamp", default: -> { "now()" }
    t.index ["user_id"], name: "index_climbs_on_user_id"
  end

  create_table "command_proposal_comments", id: :serial, force: :cascade do |t|
    t.integer "iteration_id"
    t.integer "line_number"
    t.integer "author_id"
    t.text "body"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["iteration_id"], name: "index_command_proposal_comments_on_iteration_id"
  end

  create_table "command_proposal_iterations", id: :serial, force: :cascade do |t|
    t.integer "task_id"
    t.text "args"
    t.text "code"
    t.text "result"
    t.integer "status", default: 0
    t.integer "requester_id"
    t.integer "approver_id"
    t.datetime "approved_at", precision: nil
    t.datetime "started_at", precision: nil
    t.datetime "completed_at", precision: nil
    t.datetime "stopped_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["task_id"], name: "index_command_proposal_iterations_on_task_id"
  end

  create_table "command_proposal_tasks", id: :serial, force: :cascade do |t|
    t.text "name"
    t.text "friendly_id"
    t.text "description"
    t.integer "session_type", default: 0
    t.datetime "last_executed_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "contacts", force: :cascade do |t|
    t.bigint "user_id"
    t.text "name"
    t.text "address"
    t.text "phone"
    t.float "lat"
    t.float "lng"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "nickname"
    t.jsonb "raw"
    t.text "apple_contact_id"
    t.index ["user_id"], name: "index_contacts_on_user_id"
  end

  create_table "cron_tasks", force: :cascade do |t|
    t.bigint "user_id"
    t.text "name"
    t.text "cron"
    t.text "command"
    t.boolean "enabled", default: true
    t.datetime "last_trigger_at"
    t.datetime "next_trigger_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_cron_tasks_on_user_id"
  end

  create_table "data_storages", force: :cascade do |t|
    t.string "name"
    t.text "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "emails", id: :serial, force: :cascade do |t|
    t.integer "sent_by_id"
    t.string "from"
    t.string "to"
    t.string "subject"
    t.text "blob"
    t.text "text_body"
    t.text "html_body"
    t.datetime "read_at", precision: nil
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.text "attachments"
    t.bigint "user_id"
    t.index ["sent_by_id"], name: "index_emails_on_sent_by_id"
    t.index ["user_id"], name: "index_emails_on_user_id"
  end

  create_table "flash_cards", id: :serial, force: :cascade do |t|
    t.integer "batch_id"
    t.string "title", limit: 255
    t.text "body"
    t.integer "pin"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
  end

  create_table "folder_tags", force: :cascade do |t|
    t.bigint "folder_id"
    t.bigint "tag_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["folder_id"], name: "index_folder_tags_on_folder_id"
    t.index ["tag_id"], name: "index_folder_tags_on_tag_id"
  end

  create_table "folders", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "folder_id"
    t.text "name"
    t.text "parameterized_name"
    t.integer "sort_order"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["folder_id"], name: "index_folders_on_folder_id"
    t.index ["parameterized_name"], name: "index_folders_on_parameterized_name"
    t.index ["user_id"], name: "index_folders_on_user_id"
  end

  create_table "functions", id: :serial, force: :cascade do |t|
    t.text "title"
    t.text "arguments"
    t.text "description"
    t.datetime "deploy_begin_at", precision: nil
    t.datetime "deploy_finish_at", precision: nil
    t.text "proposed_code"
    t.text "results"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "jarvis_caches", force: :cascade do |t|
    t.bigint "user_id"
    t.jsonb "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "key"
    t.index ["user_id"], name: "index_jarvis_caches_on_user_id"
  end

  create_table "jarvis_pages", force: :cascade do |t|
    t.bigint "user_id"
    t.jsonb "blocks"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_jarvis_pages_on_user_id"
  end

  create_table "jarvis_tasks", force: :cascade do |t|
    t.bigint "user_id"
    t.text "name"
    t.text "cron"
    t.integer "trigger", default: 0
    t.jsonb "last_ctx"
    t.datetime "last_trigger_at"
    t.datetime "next_trigger_at"
    t.jsonb "tasks"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "input"
    t.integer "output_type", default: 1
    t.integer "sort_order"
    t.boolean "enabled", default: true
    t.uuid "uuid", default: -> { "uuid_generate_v4()" }
    t.jsonb "return_data", default: "{\"data\":null}"
    t.text "output_text"
    t.text "listener"
    t.index ["user_id"], name: "index_jarvis_tasks_on_user_id"
  end

  create_table "jil_executions", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "jil_task_id"
    t.integer "status", default: 0
    t.jsonb "input_data"
    t.text "code"
    t.jsonb "ctx"
    t.datetime "started_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["jil_task_id"], name: "index_jil_executions_on_jil_task_id"
    t.index ["user_id"], name: "index_jil_executions_on_user_id"
  end

  create_table "jil_prompts", force: :cascade do |t|
    t.text "question"
    t.jsonb "params"
    t.jsonb "options"
    t.jsonb "response"
    t.integer "answer_type"
    t.bigint "task_id"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id"], name: "index_jil_prompts_on_task_id"
    t.index ["user_id"], name: "index_jil_prompts_on_user_id"
  end

  create_table "jil_tasks", force: :cascade do |t|
    t.uuid "uuid", default: -> { "uuid_generate_v4()" }
    t.bigint "user_id"
    t.integer "sort_order"
    t.text "name"
    t.text "cron"
    t.text "listener"
    t.text "code"
    t.boolean "enabled", default: true
    t.datetime "next_trigger_at"
    t.datetime "last_trigger_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_jil_tasks_on_user_id"
  end

  create_table "jil_usages", force: :cascade do |t|
    t.bigint "user_id"
    t.integer "executions"
    t.date "date"
    t.integer "icount"
    t.jsonb "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "date"], name: "index_jil_usages_on_user_id_and_date", unique: true
    t.index ["user_id"], name: "index_jil_usages_on_user_id"
  end

  create_table "lines", id: :serial, force: :cascade do |t|
    t.integer "flash_card_id"
    t.string "text", limit: 255
    t.boolean "center"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
  end

  create_table "list_items", id: :serial, force: :cascade do |t|
    t.text "name"
    t.integer "list_id"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "sort_order"
    t.text "formatted_name"
    t.datetime "deleted_at", precision: nil
    t.boolean "important", default: false
    t.boolean "permanent", default: false
    t.string "schedule"
    t.string "category"
    t.datetime "schedule_next", precision: nil
    t.integer "timezone"
    t.integer "amount"
    t.index ["deleted_at"], name: "index_list_items_on_deleted_at"
    t.index ["list_id"], name: "index_list_items_on_list_id"
  end

  create_table "lists", id: :serial, force: :cascade do |t|
    t.string "name", limit: 255
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.text "description"
    t.boolean "important", default: false
    t.boolean "show_deleted"
    t.text "parameterized_name"
  end

  create_table "locations", id: :serial, force: :cascade do |t|
    t.string "ip"
    t.string "country_code"
    t.string "country_name"
    t.string "region_code"
    t.string "region_name"
    t.string "city"
    t.string "zip_code"
    t.string "time_zone"
    t.float "latitude"
    t.float "longitude"
    t.string "metro_code"
  end

  create_table "log_trackers", id: :serial, force: :cascade do |t|
    t.string "user_agent"
    t.string "ip_address"
    t.string "http_method"
    t.string "url"
    t.string "params"
    t.integer "user_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "ip_count"
    t.integer "location_id"
    t.text "headers"
    t.text "body"
    t.index ["user_id"], name: "index_log_trackers_on_user_id"
  end

  create_table "money_buckets", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.text "bucket_json"
    t.index ["user_id"], name: "index_money_buckets_on_user_id"
  end

  create_table "monster_skills", id: :serial, force: :cascade do |t|
    t.integer "monster_id"
    t.string "name"
    t.text "description"
    t.string "muliplier_formula"
    t.integer "sort_order"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["monster_id"], name: "index_monster_skills_on_monster_id"
  end

  create_table "monsters", id: :serial, force: :cascade do |t|
    t.string "name"
    t.string "url"
    t.string "image_url"
    t.integer "stars"
    t.integer "element"
    t.integer "archetype"
    t.integer "health"
    t.integer "attack"
    t.integer "defense"
    t.integer "speed"
    t.integer "crit_rate"
    t.integer "crit_damage"
    t.integer "resistance"
    t.integer "accuracy"
    t.datetime "last_updated", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "page_tags", force: :cascade do |t|
    t.bigint "page_id", null: false
    t.bigint "tag_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["page_id"], name: "index_page_tags_on_page_id"
    t.index ["tag_id"], name: "index_page_tags_on_tag_id"
  end

  create_table "pages", force: :cascade do |t|
    t.string "name"
    t.text "content"
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "folder_id"
    t.text "parameterized_name"
    t.integer "sort_order"
    t.index ["folder_id"], name: "index_pages_on_folder_id"
    t.index ["user_id"], name: "index_pages_on_user_id"
  end

  create_table "pghero_query_stats", force: :cascade do |t|
    t.text "database"
    t.text "user"
    t.text "query"
    t.bigint "query_hash"
    t.float "total_time"
    t.bigint "calls"
    t.datetime "captured_at", precision: nil
  end

  create_table "recipe_favorites", id: :serial, force: :cascade do |t|
    t.integer "recipe_id"
    t.integer "favorited_by_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["favorited_by_id"], name: "index_recipe_favorites_on_favorited_by_id"
  end

  create_table "recipe_shares", id: :serial, force: :cascade do |t|
    t.integer "recipe_id"
    t.integer "shared_to_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["shared_to_id"], name: "index_recipe_shares_on_shared_to_id"
  end

  create_table "recipes", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.string "title"
    t.string "kitchen_of"
    t.text "ingredients"
    t.text "instructions"
    t.boolean "public"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.text "description"
    t.string "friendly_url"
    t.index ["user_id"], name: "index_recipes_on_user_id"
  end

  create_table "rlcraft_map_locations", id: :serial, force: :cascade do |t|
    t.integer "x_coord"
    t.integer "y_coord"
    t.string "title"
    t.string "location_type"
    t.string "description"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "survey_question_answer_results", id: :serial, force: :cascade do |t|
    t.integer "survey_id"
    t.integer "survey_result_id"
    t.integer "survey_question_id"
    t.integer "survey_question_answer_id"
    t.integer "value"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["survey_question_answer_id"], name: "index_answer_result_ids"
  end

  create_table "survey_question_answers", id: :serial, force: :cascade do |t|
    t.integer "survey_id"
    t.integer "survey_question_id"
    t.text "text"
    t.integer "position"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["survey_question_id"], name: "index_survey_question_answers_on_survey_question_id"
  end

  create_table "survey_questions", id: :serial, force: :cascade do |t|
    t.integer "survey_id"
    t.text "text"
    t.integer "position"
    t.integer "format", default: 0
    t.integer "score_split_question"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["survey_id"], name: "index_survey_questions_on_survey_id"
  end

  create_table "survey_result_details", id: :serial, force: :cascade do |t|
    t.integer "survey_id"
    t.integer "survey_result_id"
    t.text "description"
    t.integer "value"
    t.integer "conditional"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["survey_id"], name: "index_survey_result_details_on_survey_id"
    t.index ["survey_result_id"], name: "index_survey_result_details_on_survey_result_id"
  end

  create_table "survey_results", id: :serial, force: :cascade do |t|
    t.integer "survey_id"
    t.text "name"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["survey_id"], name: "index_survey_results_on_survey_id"
  end

  create_table "surveys", id: :serial, force: :cascade do |t|
    t.text "name"
    t.text "slug"
    t.text "description"
    t.boolean "randomize_answers", default: true
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "score_type", default: 0
  end

  create_table "tags", force: :cascade do |t|
    t.text "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "user_lists", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.integer "list_id"
    t.boolean "is_owner"
    t.integer "sort_order"
    t.boolean "default", default: false
    t.index ["list_id"], name: "index_user_lists_on_list_id"
    t.index ["user_id"], name: "index_user_lists_on_user_id"
  end

  create_table "user_push_subscriptions", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.string "sub_auth"
    t.string "endpoint"
    t.string "p256dh"
    t.string "auth"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "registered_at", precision: nil
    t.index ["user_id"], name: "index_user_push_subscriptions_on_user_id"
  end

  create_table "user_survey_responses", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.integer "survey_id"
    t.integer "user_survey_id"
    t.integer "survey_question_id"
    t.integer "survey_question_answer_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["survey_question_answer_id"], name: "index_user_survey_responses_on_survey_question_answer_id"
    t.index ["user_id"], name: "index_user_survey_responses_on_user_id"
    t.index ["user_survey_id"], name: "index_user_survey_responses_on_user_survey_id"
  end

  create_table "user_surveys", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.integer "survey_id"
    t.text "token"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["survey_id"], name: "index_user_surveys_on_survey_id"
    t.index ["user_id"], name: "index_user_surveys_on_user_id"
  end

  create_table "users", id: :serial, force: :cascade do |t|
    t.string "username"
    t.string "password_digest"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "phone"
    t.string "invitation_token"
    t.integer "role", default: 0
    t.boolean "dark_mode"
    t.string "email"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "page_tags", "pages"
  add_foreign_key "page_tags", "tags"
  add_foreign_key "pages", "users"
end
