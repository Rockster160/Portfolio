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

ActiveRecord::Schema[7.1].define(version: 2026_06_17_123641) do
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
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
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

  create_table "agenda_items", force: :cascade do |t|
    t.bigint "agenda_id", null: false
    t.bigint "agenda_schedule_id"
    t.integer "kind", null: false
    t.datetime "start_at", null: false
    t.datetime "end_at"
    t.datetime "completed_at"
    t.datetime "detached_at"
    t.string "name", null: false
    t.text "notes"
    t.string "location"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "color"
    t.text "trigger_expression"
    t.datetime "notified_at"
    t.datetime "original_start_at"
    t.text "external_uid"
    t.text "external_etag"
    t.datetime "external_updated_at"
    t.boolean "all_day", default: false, null: false
    t.datetime "locally_modified_at"
    t.string "local_color"
    t.datetime "cancelled_at"
    t.integer "status", default: 0, null: false
    t.datetime "fired_at"
    t.datetime "ended_fired_at"
    t.jsonb "metadata", default: {}, null: false
    t.integer "arrive_early_minutes", default: 0, null: false
    t.index ["agenda_id", "external_uid"], name: "index_agenda_items_on_agenda_external_uid", unique: true, where: "(external_uid IS NOT NULL)"
    t.index ["agenda_id", "start_at"], name: "index_agenda_items_on_agenda_id_and_start_at"
    t.index ["agenda_id"], name: "index_agenda_items_on_agenda_id"
    t.index ["agenda_schedule_id", "start_at"], name: "index_agenda_items_on_agenda_schedule_id_and_start_at"
    t.index ["agenda_schedule_id"], name: "index_agenda_items_on_agenda_schedule_id"
    t.index ["cancelled_at"], name: "index_agenda_items_on_cancelled_at", where: "(cancelled_at IS NOT NULL)"
    t.index ["completed_at"], name: "index_agenda_items_on_completed_at"
    t.index ["fired_at"], name: "index_agenda_items_on_fired_at", where: "(fired_at IS NOT NULL)"
    t.index ["notified_at"], name: "index_agenda_items_on_notified_at"
    t.index ["status"], name: "index_agenda_items_on_status"
  end

  create_table "agenda_notification_settings", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "agenda_id", null: false
    t.boolean "notify_task_oneoff", default: true, null: false
    t.boolean "notify_task_recurring", default: true, null: false
    t.boolean "notify_event_oneoff", default: true, null: false
    t.boolean "notify_event_recurring", default: true, null: false
    t.boolean "notify_trigger_oneoff", default: false, null: false
    t.boolean "notify_trigger_recurring", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agenda_id"], name: "index_agenda_notification_settings_on_agenda_id"
    t.index ["user_id", "agenda_id"], name: "index_agenda_notification_settings_on_user_id_and_agenda_id", unique: true
    t.index ["user_id"], name: "index_agenda_notification_settings_on_user_id"
  end

  create_table "agenda_preferences", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.jsonb "hidden_agenda_ids", default: [], null: false
    t.jsonb "hide_completed", default: {}, null: false
    t.boolean "hide_tentative", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "hidden_schedule_ids", default: [], null: false
    t.jsonb "hidden_name_patterns", default: [], null: false
    t.jsonb "hidden_item_ids", default: [], null: false
    t.index ["user_id"], name: "index_agenda_preferences_on_user_id", unique: true
  end

  create_table "agenda_schedules", force: :cascade do |t|
    t.bigint "agenda_id", null: false
    t.string "name", null: false
    t.integer "kind", null: false
    t.time "start_time", null: false
    t.integer "duration_minutes"
    t.date "starts_on", null: false
    t.date "until_on"
    t.jsonb "recurrence", default: {}, null: false
    t.text "notes"
    t.string "location"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "color"
    t.text "trigger_expression"
    t.integer "occurrence_count"
    t.text "external_uid"
    t.text "external_etag"
    t.datetime "external_updated_at"
    t.boolean "all_day", default: false, null: false
    t.jsonb "metadata", default: {}, null: false
    t.integer "arrive_early_minutes", default: 0, null: false
    t.index ["agenda_id", "external_uid"], name: "index_agenda_schedules_on_agenda_external_uid", unique: true, where: "(external_uid IS NOT NULL)"
    t.index ["agenda_id"], name: "index_agenda_schedules_on_agenda_id"
  end

  create_table "agenda_shares", force: :cascade do |t|
    t.bigint "agenda_id", null: false
    t.bigint "user_id", null: false
    t.integer "permission", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agenda_id", "user_id"], name: "index_agenda_shares_on_agenda_id_and_user_id", unique: true
    t.index ["agenda_id"], name: "index_agenda_shares_on_agenda_id"
    t.index ["user_id"], name: "index_agenda_shares_on_user_id"
  end

  create_table "agendas", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.string "parameterized_name", null: false
    t.string "color"
    t.integer "sort_order"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "source", default: 0, null: false
    t.text "external_id"
    t.text "sync_token"
    t.datetime "synced_at"
    t.text "watch_channel_id"
    t.text "watch_resource_id"
    t.datetime "watch_expires_at"
    t.datetime "watch_failed_at"
    t.bigint "google_account_id"
    t.string "sync_reason"
    t.index ["google_account_id"], name: "index_agendas_on_google_account_id"
    t.index ["user_id", "parameterized_name"], name: "index_agendas_on_user_id_and_parameterized_name", unique: true
    t.index ["user_id", "source", "google_account_id", "external_id"], name: "index_agendas_on_user_source_account_external", unique: true, where: "(source <> 0)"
    t.index ["user_id"], name: "index_agendas_on_user_id"
    t.index ["watch_channel_id"], name: "index_agendas_on_watch_channel_id", unique: true, where: "(watch_channel_id IS NOT NULL)"
    t.index ["watch_expires_at"], name: "index_agendas_on_watch_expires_at", where: "(watch_expires_at IS NOT NULL)"
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

  create_table "boxes", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "name", null: false
    t.text "description"
    t.integer "sort_order", null: false
    t.jsonb "data", default: {}, null: false
    t.text "notes"
    t.boolean "empty", default: true, null: false
    t.jsonb "hierarchy_ids", default: [], null: false
    t.jsonb "hierarchy_data", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "param_key"
    t.text "hierarchy"
    t.text "parent_key"
    t.index ["param_key"], name: "index_boxes_on_param_key", unique: true
    t.index ["parent_key"], name: "index_boxes_on_parent_key"
    t.index ["user_id"], name: "index_boxes_on_user_id"
  end

  create_table "chore_completions", force: :cascade do |t|
    t.bigint "chore_id", null: false
    t.bigint "user_id", null: false
    t.datetime "completed_at", null: false
    t.date "day_key", null: false
    t.integer "paid_pebbles", default: 0, null: false
    t.integer "base_pebbles", default: 0, null: false
    t.float "hot_multiplier", default: 1.0, null: false
    t.integer "achievement_bonus_pebbles", default: 0, null: false
    t.boolean "payout_skipped", default: false, null: false
    t.text "skipped_reason"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "note"
    t.float "streak_multiplier", default: 1.0, null: false
    t.boolean "anonymous", default: false, null: false
    t.bigint "sub_chore_id"
    t.index ["chore_id", "user_id", "day_key"], name: "index_chore_completions_on_chore_id_and_user_id_and_day_key"
    t.index ["chore_id"], name: "index_chore_completions_on_chore_id"
    t.index ["sub_chore_id"], name: "index_chore_completions_on_sub_chore_id"
    t.index ["user_id", "completed_at"], name: "index_chore_completions_on_user_id_and_completed_at"
    t.index ["user_id", "day_key"], name: "index_chore_completions_on_user_id_and_day_key"
    t.index ["user_id"], name: "index_chore_completions_on_user_id"
  end

  create_table "chore_dailies", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "chore_id", null: false
    t.integer "sort_order", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chore_id"], name: "index_chore_dailies_on_chore_id"
    t.index ["user_id", "chore_id"], name: "index_chore_dailies_on_user_id_and_chore_id", unique: true
    t.index ["user_id", "sort_order"], name: "index_chore_dailies_on_user_id_and_sort_order"
    t.index ["user_id"], name: "index_chore_dailies_on_user_id"
  end

  create_table "chore_goals", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.text "image_url"
    t.text "link_url"
    t.datetime "achieved_at"
    t.datetime "archived_at"
    t.integer "sort_order"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "kind", default: 0, null: false
    t.integer "scope_mode", default: 0, null: false
    t.integer "tracking_mode", default: 0, null: false
    t.integer "target_value", default: 0, null: false
    t.integer "baseline_value", default: 0, null: false
    t.integer "awarded_pebbles", default: 0, null: false
    t.text "description"
    t.jsonb "config", default: {}, null: false
    t.bigint "chore_id"
    t.index ["chore_id"], name: "index_chore_goals_on_chore_id"
    t.index ["user_id", "archived_at"], name: "index_chore_goals_on_user_id_and_archived_at"
    t.index ["user_id"], name: "index_chore_goals_on_user_id"
  end

  create_table "chore_hot_picks", force: :cascade do |t|
    t.date "day_key", null: false
    t.bigint "chore_id", null: false
    t.float "multiplier", default: 2.0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chore_id"], name: "index_chore_hot_picks_on_chore_id"
    t.index ["day_key", "chore_id"], name: "index_chore_hot_picks_on_day_key_and_chore_id", unique: true
  end

  create_table "chore_household_memberships", force: :cascade do |t|
    t.bigint "chore_household_id", null: false
    t.bigint "user_id", null: false
    t.integer "role", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chore_household_id", "user_id"], name: "index_chore_household_memberships_pair", unique: true
    t.index ["chore_household_id"], name: "index_chore_household_memberships_on_chore_household_id"
    t.index ["user_id"], name: "index_chore_household_memberships_on_user_id"
    t.index ["user_id"], name: "index_chore_household_memberships_unique_user", unique: true
  end

  create_table "chore_households", force: :cascade do |t|
    t.bigint "owner_user_id", null: false
    t.text "name", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_user_id"], name: "index_chore_households_on_owner_user_id"
  end

  create_table "chore_streak_bonuses", force: :cascade do |t|
    t.string "name", null: false
    t.integer "kind", default: 0, null: false
    t.jsonb "config", default: {}, null: false
    t.boolean "active", default: true, null: false
    t.integer "sort_order"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "chore_id"
    t.bigint "chore_household_id", null: false
    t.index ["chore_household_id", "active"], name: "index_chore_streak_bonuses_on_chore_household_id_and_active"
    t.index ["chore_id"], name: "index_chore_streak_bonuses_on_chore_id"
  end

  create_table "chore_streaks", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "chore_id", null: false
    t.integer "current_streak", default: 0, null: false
    t.integer "longest_streak", default: 0, null: false
    t.date "last_completed_day"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chore_id"], name: "index_chore_streaks_on_chore_id"
    t.index ["user_id", "chore_id"], name: "index_chore_streaks_on_user_id_and_chore_id", unique: true
    t.index ["user_id"], name: "index_chore_streaks_on_user_id"
  end

  create_table "chore_transfers", force: :cascade do |t|
    t.bigint "from_user_id", null: false
    t.bigint "to_user_id", null: false
    t.integer "amount_pebbles", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_user_id"], name: "index_chore_transfers_on_from_user_id"
    t.index ["to_user_id"], name: "index_chore_transfers_on_to_user_id"
    t.check_constraint "amount_pebbles > 0", name: "chore_transfers_positive_amount"
    t.check_constraint "from_user_id <> to_user_id", name: "chore_transfers_distinct_endpoints"
  end

  create_table "chore_withdrawals", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "amount_pebbles", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "created_at"], name: "index_chore_withdrawals_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_chore_withdrawals_on_user_id"
  end

  create_table "chores", force: :cascade do |t|
    t.bigint "created_by_user_id", null: false
    t.text "name", null: false
    t.text "short_name"
    t.text "icon"
    t.jsonb "aliases", default: [], null: false
    t.integer "reward_pebbles", default: 0, null: false
    t.integer "threshold_seconds"
    t.jsonb "recurrence"
    t.date "starts_on"
    t.boolean "one_off", default: false, null: false
    t.datetime "archived_at"
    t.integer "sort_order"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "show_on_today_view", default: 1, null: false
    t.integer "sharing_mode", default: 0, null: false
    t.bigint "assigned_to_user_id"
    t.text "notes_template"
    t.bigint "chore_household_id", null: false
    t.integer "hot_eligibility", default: 0, null: false
    t.text "notes"
    t.datetime "marked_due_at"
    t.bigint "parent_chore_id"
    t.integer "target_count", default: 1, null: false
    t.index ["archived_at"], name: "index_chores_on_archived_at"
    t.index ["assigned_to_user_id"], name: "index_chores_on_assigned_to_user_id"
    t.index ["chore_household_id", "archived_at"], name: "index_chores_on_chore_household_id_and_archived_at"
    t.index ["chore_household_id", "sort_order"], name: "index_chores_active_by_household_sort", where: "(archived_at IS NULL)"
    t.index ["chore_household_id", "sort_order"], name: "index_chores_on_chore_household_id_and_sort_order"
    t.index ["one_off"], name: "index_chores_on_one_off"
    t.index ["parent_chore_id"], name: "index_chores_on_parent_chore_id"
    t.index ["reward_pebbles"], name: "index_chores_on_reward_pebbles"
    t.index ["show_on_today_view"], name: "index_chores_on_show_on_today_view"
  end

  create_table "climbs", force: :cascade do |t|
    t.bigint "user_id"
    t.text "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "timestamp", default: -> { "now()" }
    t.integer "total_pennies"
    t.jsonb "scores"
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
    t.jsonb "data", default: {}
    t.bigint "friend_id"
    t.boolean "permit_relay", default: true
    t.index ["friend_id"], name: "index_contacts_on_friend_id"
    t.index ["user_id"], name: "index_contacts_on_user_id"
  end

  create_table "data_storages", force: :cascade do |t|
    t.string "name"
    t.text "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "emails", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "direction", null: false
    t.jsonb "inbound_mailboxes", default: [], null: false
    t.jsonb "outbound_mailboxes", default: [], null: false
    t.text "subject", null: false
    t.text "blurb", null: false
    t.boolean "has_attachments", default: false, null: false
    t.datetime "timestamp", null: false
    t.datetime "read_at"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "mail_id", null: false
    t.index ["mail_id", "timestamp"], name: "index_emails_on_mail_id_and_timestamp"
    t.index ["user_id"], name: "index_emails_on_user_id"
  end

  create_table "execution_payloads", force: :cascade do |t|
    t.text "code"
    t.jsonb "input_data"
    t.jsonb "ctx"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "executions", force: :cascade do |t|
    t.bigint "user_id"
    t.bigint "task_id"
    t.integer "status", default: 0
    t.datetime "started_at", default: -> { "now()" }
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "auth_type"
    t.integer "auth_type_id"
    t.bigint "payload_id"
    t.string "trigger_scope"
    t.index ["started_at"], name: "index_executions_on_started_at"
    t.index ["task_id", "started_at"], name: "index_executions_on_task_id_and_started_at", order: { started_at: :desc }
    t.index ["trigger_scope"], name: "index_executions_on_trigger_scope"
    t.index ["user_id", "started_at"], name: "index_executions_on_user_id_and_started_at", order: { started_at: :desc }
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

  create_table "google_accounts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "email", null: false
    t.text "access_token"
    t.text "refresh_token"
    t.text "id_token"
    t.datetime "tokens_refreshed_at"
    t.datetime "reauth_required_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "disconnected_at"
    t.index ["user_id", "email"], name: "index_google_accounts_on_user_id_and_email", unique: true
    t.index ["user_id"], name: "index_google_accounts_on_user_id"
  end

  create_table "household_icons", force: :cascade do |t|
    t.bigint "chore_household_id", null: false
    t.bigint "uploaded_by_user_id", null: false
    t.text "name", null: false
    t.text "keywords", default: "", null: false
    t.text "image_data", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chore_household_id", "name"], name: "index_household_icons_on_chore_household_id_and_name", unique: true
    t.index ["chore_household_id"], name: "index_household_icons_on_chore_household_id"
    t.index ["uploaded_by_user_id"], name: "index_household_icons_on_uploaded_by_user_id"
  end

  create_table "lines", id: :serial, force: :cascade do |t|
    t.integer "flash_card_id"
    t.string "text", limit: 255
    t.boolean "center"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
  end

  create_table "list_builders", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "list_id", null: false
    t.text "name", null: false
    t.text "parameterized_name", null: false
    t.jsonb "items", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id"], name: "index_list_builders_on_list_id"
    t.index ["user_id", "name"], name: "index_list_builders_on_user_id_and_name", unique: true
    t.index ["user_id", "parameterized_name"], name: "index_list_builders_on_user_id_and_parameterized_name", unique: true
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
    t.string "category"
    t.integer "amount"
    t.bigint "section_id"
    t.index ["deleted_at"], name: "index_list_items_on_deleted_at"
    t.index ["list_id"], name: "index_list_items_on_list_id"
    t.index ["section_id"], name: "index_list_items_on_section_id"
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

  create_table "log_trackers", force: :cascade do |t|
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
    t.index ["created_at"], name: "index_log_trackers_on_created_at"
    t.index ["ip_address"], name: "index_log_trackers_on_ip_address"
    t.index ["user_id"], name: "index_log_trackers_on_user_id"
  end

  create_table "meal_builders", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "name", null: false
    t.text "parameterized_name", null: false
    t.jsonb "items", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "name"], name: "index_meal_builders_on_user_id_and_name", unique: true
    t.index ["user_id", "parameterized_name"], name: "index_meal_builders_on_user_id_and_parameterized_name", unique: true
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

  create_table "oauth_access_grants", force: :cascade do |t|
    t.bigint "resource_owner_id", null: false
    t.bigint "application_id", null: false
    t.string "token", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.bigint "resource_owner_id"
    t.bigint "application_id", null: false
    t.string "token", null: false
    t.string "refresh_token"
    t.integer "expires_in"
    t.string "scopes"
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.string "previous_refresh_token", default: "", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.string "name", null: false
    t.string "uid", null: false
    t.string "secret", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
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

  create_table "prompts", force: :cascade do |t|
    t.text "question"
    t.jsonb "params"
    t.jsonb "options"
    t.jsonb "response"
    t.integer "answer_type"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_prompts_on_user_id"
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

  create_table "scheduled_triggers", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "trigger", null: false
    t.jsonb "data", default: {}, null: false
    t.datetime "execute_at", null: false
    t.text "jid"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "name"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.integer "auth_type"
    t.integer "auth_type_id"
    t.bigint "source_item_id"
    t.integer "offset_seconds"
    t.index ["source_item_id"], name: "index_scheduled_triggers_on_source_item_id"
    t.index ["user_id"], name: "index_scheduled_triggers_on_user_id"
  end

  create_table "sections", force: :cascade do |t|
    t.text "name", null: false
    t.text "color", null: false
    t.integer "sort_order", null: false
    t.bigint "list_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id"], name: "index_sections_on_list_id"
  end

  create_table "shared_pages", force: :cascade do |t|
    t.bigint "page_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["page_id", "user_id"], name: "index_shared_pages_on_page_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_shared_pages_on_user_id"
  end

  create_table "shared_tasks", force: :cascade do |t|
    t.bigint "task_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id", "user_id"], name: "index_shared_tasks_on_task_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_shared_tasks_on_user_id"
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

  create_table "task_folders", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "parent_id"
    t.text "name", null: false
    t.integer "sort_order"
    t.boolean "collapsed", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id"], name: "index_task_folders_on_parent_id"
    t.index ["user_id"], name: "index_task_folders_on_user_id"
  end

  create_table "tasks", force: :cascade do |t|
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
    t.integer "last_status"
    t.bigint "task_folder_id"
    t.integer "tree_order"
    t.datetime "archived_at"
    t.index ["task_folder_id"], name: "index_tasks_on_task_folder_id"
    t.index ["user_id"], name: "index_tasks_on_user_id"
  end

  create_table "timer_page_buttons", force: :cascade do |t|
    t.bigint "timer_page_id", null: false
    t.text "label", default: "", null: false
    t.text "color"
    t.text "target_url", null: false
    t.integer "sort_order", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["timer_page_id", "sort_order"], name: "index_timer_page_buttons_on_timer_page_id_and_sort_order"
    t.index ["timer_page_id"], name: "index_timer_page_buttons_on_timer_page_id"
  end

  create_table "timer_pages", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "name", default: "", null: false
    t.text "slug", null: false
    t.integer "sort_order", default: 0, null: false
    t.integer "layout_mode", default: 0, null: false
    t.jsonb "sections", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "meta", default: {}, null: false
    t.index ["user_id", "slug"], name: "index_timer_pages_on_user_id_and_slug", unique: true
    t.index ["user_id"], name: "index_timer_pages_on_user_id"
  end

  create_table "timer_quick_buttons", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "label"
    t.integer "duration_seconds"
    t.integer "sort_order", default: 0, null: false
    t.text "color"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "template", default: {}, null: false
    t.boolean "pinned", default: true, null: false
    t.bigint "timer_page_id"
    t.index ["timer_page_id"], name: "index_timer_quick_buttons_on_timer_page_id"
    t.index ["user_id", "pinned", "sort_order"], name: "index_timer_quick_buttons_on_user_id_and_pinned_and_sort_order"
    t.index ["user_id", "sort_order"], name: "index_timer_quick_buttons_on_user_id_and_sort_order"
    t.index ["user_id"], name: "index_timer_quick_buttons_on_user_id"
  end

  create_table "timer_share_tokens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "timer_id"
    t.bigint "timer_page_id"
    t.string "token", null: false
    t.integer "access_mode", default: 0, null: false
    t.datetime "revoked_at"
    t.datetime "expires_at"
    t.integer "hit_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["timer_id"], name: "index_timer_share_tokens_on_timer_id"
    t.index ["timer_page_id"], name: "index_timer_share_tokens_on_timer_page_id"
    t.index ["token"], name: "index_timer_share_tokens_on_token", unique: true
    t.index ["user_id"], name: "index_timer_share_tokens_on_user_id"
    t.check_constraint "((timer_id IS NOT NULL)::integer + (timer_page_id IS NOT NULL)::integer) = 1", name: "timer_share_tokens_target_xor"
  end

  create_table "timers", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "timer_page_id"
    t.text "name", default: "", null: false
    t.integer "kind", default: 0, null: false
    t.text "color"
    t.integer "section_id"
    t.integer "pos_x", default: 0, null: false
    t.integer "pos_y", default: 0, null: false
    t.integer "width", default: 0, null: false
    t.integer "height", default: 0, null: false
    t.bigint "duration_ms"
    t.datetime "started_at"
    t.datetime "paused_at"
    t.bigint "paused_remaining_ms"
    t.datetime "end_at"
    t.boolean "repeat", default: false, null: false
    t.integer "repeat_count", default: 0, null: false
    t.boolean "require_confirm_tap", default: false, null: false
    t.integer "value", default: 0, null: false
    t.integer "step", default: 1, null: false
    t.integer "min_value"
    t.integer "max_value"
    t.integer "reset_value", default: 0, null: false
    t.jsonb "dial_config", default: {}, null: false
    t.integer "dial_step_index", default: 0, null: false
    t.jsonb "callbacks", default: [], null: false
    t.string "fire_jid"
    t.datetime "fire_scheduled_for"
    t.datetime "fired_at"
    t.datetime "confirmed_at"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "disabled", default: false, null: false
    t.index ["end_at"], name: "index_timers_pending_fire", where: "((end_at IS NOT NULL) AND (fired_at IS NULL))"
    t.index ["fire_jid"], name: "index_timers_on_fire_jid", unique: true, where: "(fire_jid IS NOT NULL)"
    t.index ["timer_page_id"], name: "index_timers_on_timer_page_id"
    t.index ["user_id", "kind", "archived_at"], name: "index_timers_on_user_id_and_kind_and_archived_at"
    t.index ["user_id"], name: "index_timers_on_user_id"
  end

  create_table "user_caches", force: :cascade do |t|
    t.bigint "user_id"
    t.jsonb "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "key"
    t.index ["user_id", "key"], name: "index_user_caches_on_user_id_and_key", unique: true
    t.index ["user_id"], name: "index_user_caches_on_user_id"
  end

  create_table "user_dashboards", force: :cascade do |t|
    t.bigint "user_id"
    t.jsonb "blocks"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_user_dashboards_on_user_id"
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
    t.string "channel", default: "jarvis", null: false
    t.index ["user_id", "channel"], name: "index_user_push_subscriptions_on_user_id_and_channel"
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
    t.bigint "chore_household_id"
    t.jsonb "chore_notify_prefs", default: {}, null: false
    t.index ["chore_household_id"], name: "index_users_on_chore_household_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agenda_items", "agenda_schedules"
  add_foreign_key "agenda_items", "agendas"
  add_foreign_key "agenda_notification_settings", "agendas"
  add_foreign_key "agenda_notification_settings", "users"
  add_foreign_key "agenda_preferences", "users"
  add_foreign_key "agenda_schedules", "agendas"
  add_foreign_key "agenda_shares", "agendas"
  add_foreign_key "agenda_shares", "users"
  add_foreign_key "agendas", "google_accounts"
  add_foreign_key "agendas", "users"
  add_foreign_key "boxes", "users"
  add_foreign_key "chore_completions", "chores"
  add_foreign_key "chore_completions", "chores", column: "sub_chore_id"
  add_foreign_key "chore_completions", "users"
  add_foreign_key "chore_dailies", "chores", on_delete: :cascade
  add_foreign_key "chore_dailies", "users", on_delete: :cascade
  add_foreign_key "chore_goals", "chores"
  add_foreign_key "chore_goals", "users"
  add_foreign_key "chore_hot_picks", "chores"
  add_foreign_key "chore_household_memberships", "chore_households", on_delete: :cascade
  add_foreign_key "chore_household_memberships", "users"
  add_foreign_key "chore_households", "users", column: "owner_user_id"
  add_foreign_key "chore_streak_bonuses", "chore_households"
  add_foreign_key "chore_streak_bonuses", "chores"
  add_foreign_key "chore_streaks", "chores"
  add_foreign_key "chore_streaks", "users"
  add_foreign_key "chore_transfers", "users", column: "from_user_id"
  add_foreign_key "chore_transfers", "users", column: "to_user_id"
  add_foreign_key "chore_withdrawals", "users"
  add_foreign_key "chores", "chore_households"
  add_foreign_key "chores", "chores", column: "parent_chore_id"
  add_foreign_key "chores", "users", column: "assigned_to_user_id"
  add_foreign_key "chores", "users", column: "created_by_user_id"
  add_foreign_key "emails", "users"
  add_foreign_key "google_accounts", "users"
  add_foreign_key "household_icons", "chore_households", on_delete: :cascade
  add_foreign_key "household_icons", "users", column: "uploaded_by_user_id"
  add_foreign_key "list_builders", "lists"
  add_foreign_key "list_builders", "users"
  add_foreign_key "list_items", "sections"
  add_foreign_key "meal_builders", "users"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_grants", "users", column: "resource_owner_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "users", column: "resource_owner_id"
  add_foreign_key "page_tags", "pages"
  add_foreign_key "page_tags", "tags"
  add_foreign_key "pages", "users"
  add_foreign_key "scheduled_triggers", "agenda_items", column: "source_item_id", on_delete: :cascade
  add_foreign_key "sections", "lists"
  add_foreign_key "shared_pages", "pages"
  add_foreign_key "shared_pages", "users"
  add_foreign_key "shared_tasks", "tasks"
  add_foreign_key "shared_tasks", "users"
  add_foreign_key "task_folders", "task_folders", column: "parent_id"
  add_foreign_key "task_folders", "users"
  add_foreign_key "tasks", "task_folders"
  add_foreign_key "timer_page_buttons", "timer_pages", on_delete: :cascade
  add_foreign_key "timer_pages", "users"
  add_foreign_key "timer_quick_buttons", "timer_pages"
  add_foreign_key "timer_quick_buttons", "users"
  add_foreign_key "timer_share_tokens", "timer_pages"
  add_foreign_key "timer_share_tokens", "timers"
  add_foreign_key "timer_share_tokens", "users"
  add_foreign_key "timers", "timer_pages"
  add_foreign_key "timers", "users"
  add_foreign_key "users", "chore_households"
end
