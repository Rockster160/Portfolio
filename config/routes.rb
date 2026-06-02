Rails.application.routes.draw do
  use_doorkeeper

  get "/blockly" => "index#blockly"
  get "/icons" => "index#icons"
  get "/mtg-glossary" => "index#mtg_glossary"
  get "/lorcana-glossary" => "index#lorcana_glossary"
  get "/privacy-policy" => "index#privacy_policy"

  constraints subdomain: "sub" do
    get "/sub" => "index#sub"
  end

  constraints subdomain: "whisper" do
    root "whisper#show", as: :whisper_root
  end

  post "tesla/api/1/vehicles/:vin/command/:command" => "vehicles#command"
  post "tesla/oauth2/v3/token" => "vehicles#token"

  root "index#home"
  post "/talk" => "index#talk"
  get "/nest_subscribe" => "index#nest_subscribe"
  post "/jarvis/command" => "jarvis#command"
  post "/jarvis" => "jarvis#command"
  post "proxy" => "proxy#proxy"
  post "/printer_control" => "printers#control"
  get "map" => "index#map"
  get "playground" => "index#playground"
  resource :ping, only: :create

  resource :whisper, only: [:show], controller: :whisper

  namespace :internal do
    get "auth", to: "auth#check"
  end

  namespace :api do
    namespace :v1 do
      post :alexa, controller: :alexa

      resources :lists, only: [:index, :show, :update, :create, :destroy] do
        post :reorder, on: :collection
        put :order_items, on: :member

        resources :list_items, only: [:index, :show, :update, :create, :destroy] do
          patch :update, on: :collection
          delete :destroy, on: :collection
        end

        resources :sections, only: [:index, :show, :update, :create, :destroy] do
          patch :update, on: :collection
          delete :destroy, on: :collection
        end
        # resources :user_lists, only: [:index, :create, :destroy], path: :users
      end
    end
  end

  resource :jarvis, only: [:show, :update], controller: :quick_actions, as: :user_dashboard do
    get :sync_badge
    get :render_widget
  end

  scope path: :jarvis do
    resources :meal_builders
    resources :list_builders do
      get :manifest, on: :member
      post :toggle_item, on: :member
      patch :update_stock, on: :member
    end
  end

  resources :dashboards, only: [:show, :update], controller: :quick_actions do
    get "/create", on: :collection, action: :get_create
    get :sync_badge
    get :render_widget
  end
  resources :prompts, only: [:index, :show, :update, :destroy], path: :prompts

  scope module: :users do
    get :login,         controller: :sessions,      action: :new
    post :login,        controller: :sessions,      action: :create
    get :logout,        controller: :sessions,      action: :destroy
    delete :logout,     controller: :sessions,      action: :destroy
    get :register,      controller: :registrations, action: :new
    post :register,     controller: :registrations, action: :create
    patch :register,    controller: :registrations, action: :create
    post :guest_signup, controller: :registrations, action: :guest_signup
  end

  resource :money_buckets, path: "/bucket"

  # Chores / Pebbles gamification.
  #   /chores         — list-builder style grid (all chores, search, tap to complete)
  #   /chores/today   — checkbox/circle style (today's scheduled chores + carryovers)
  #   /chores/balance — balance, goals, multipliers, achievements, withdrawals
  get  "/chores"         => "chores#index",   as: :chores
  get  "/chores/today"   => "chores#today",   as: :chores_today
  get  "/chores/balance" => "chores#balance", as: :chores_balance
  get  "/chores/history"        => "chores#history",        as: :chores_history
  get  "/chores/recent_history" => "chores#recent_history", as: :chores_recent_history
  get  "/chores/csrf"           => "chores#csrf",           as: :chores_csrf
  get  "/chores/sync"    => "chores#sync",    as: :chores_sync
  scope path: "chores", as: :chore_routes do
    get  "/new"          => "chores#new",            as: :new
    get  "/items/:id/edit" => "chores#edit",         as: :edit
    post "/items"        => "chores#create",         as: :items
    patch  "/items/:id"  => "chores#update",         as: :item
    put    "/items/:id"  => "chores#update"
    delete "/items/:id"  => "chores#destroy"
    post   "/items/:chore_id/completion" => "chore_completions#create", as: :complete_item
    delete "/items/:chore_id/completion" => "chore_completions#destroy"
    get    "/items/:id/state"            => "chores#state",              as: :item_state
    get    "/items/:id/history"          => "chores#chore_history",      as: :item_history
    patch  "/order"                      => "chores#reorder",            as: :reorder
    post   "/items/:id/dailies"          => "chores#pin_daily",          as: :pin_daily
    delete "/items/:id/dailies"          => "chores#unpin_daily",        as: :unpin_daily
    patch  "/dailies/order"              => "chores#reorder_dailies",    as: :reorder_dailies
    resources :completions, controller: :chore_completions, only: [:update, :destroy]
    resources :goals,         controller: :chore_goals,          only: [:create, :update, :destroy], as: :goals
    resources :streak_bonuses, controller: :chore_streak_bonuses, only: [:create, :update, :destroy], as: :streak_bonuses
    resources :withdrawals,   controller: :chore_withdrawals,    only: [:create, :update, :destroy], as: :withdrawals
    resources :transfers,     controller: :chore_transfers,      only: [:create, :update, :destroy], as: :transfers
  end

  post "webhooks/tesla_telemetry" => "webhooks#tesla_telemetry"
  post "webhooks/tesla_local" => "webhooks#tesla_local"
  post "jil/trigger/:trigger" => "webhooks#jil"
  post "jil/trigger" => "webhooks#jil"
  post "webhooks/jil(/:uuid)" => "webhooks#execute_task"
  get "webhooks/jil(/:uuid)" => "webhooks#execute_task"
  post "webhooks/battery" => "webhooks#battery"
  post "webhooks/report" => "webhooks#report"
  get "webhooks/local_ping" => "webhooks#local_ping"
  post "webhooks/local_ping" => "webhooks#local_ping"
  post "webhooks/jenkins" => "webhooks#jenkins"
  post "webhooks/post" => "webhooks#post"
  post "webhooks/email" => "webhooks#email"
  post "webhooks/speak" => "webhooks#speak"

  get "webhooks/uptime" => "webhooks#uptime"
  post "webhooks/uptime" => "webhooks#uptime"
  # Deprecated. This is list specific. Bad!
  post "webhooks/command" => "webhooks#list_command"
  get "webhooks/auth" => "webhooks#auth"
  get "webhooks/auth/:service" => "webhooks#auth"
  get "webhooks/oauth/:service" => "webhooks#auth"
  post "push_notification_subscribe" => "webhooks#push_notification_subscribe"
  post "push_notification_unsubscribe" => "webhooks#push_notification_unsubscribe"
  post "push_diagnostic" => "webhooks#push_diagnostic"

  get "dashboard" => "dashboard#show"
  resource :dashboard, controller: :dashboard, only: [:show] do
    get :demo, on: :collection
    collection do
      get :octoprint_session
    end
  end

  resource :nfc, only: [:show]

  resources :emails, except: [:destroy, :edit]
  resources :log_trackers, only: [:index, :show]
  post "/ips/ban" => "log_trackers#ban", as: :ban_ip

  resources :surveys
  resources :survey_responses

  resource :calc, only: [:show]

  resources :action_events do
    get :calendar, on: :collection
    get :pullups, on: :collection
    get :feelings, on: :collection
  end

  resource :inventory, controller: :inventory_management do
    resources :boxes do
      collection do
        get :batch
      end
    end
    get :export
    post :import
    post :restore
  end
  get "/b/:id" => "inventory_management#box", as: :box

  resources :scheduled_tasks, path: :schedules

  resource :summoners_war do
    get :runes
    resources :monsters
    resources :monster_skills
  end

  get :account, controller: :users
  resources :api_keys, except: :show
  resources :users, only: [:new, :create, :update]
  resources :lists do
    post :reorder, on: :collection
    member do
      get :manifest
      post :modify_from_message
      post :receive_update
    end
    resources :user_lists, only: [:index, :create, :destroy], path: :users
    resources :list_items
    resources :sections, only: [:edit, :create, :update, :destroy]
  end

  # Everything users NAVIGATE to lives under /agenda/* so the PWA scope
  # ("/agenda" in agenda.webmanifest) covers all of it — manage, edit, new,
  # share routes don't pop the user out of the installed app.
  #
  # Helpers are named after the VIEW (not the resource) for the singular
  # routes so they don't collide with the resourceful agenda_path(record).
  get "/agenda"          => "agendas#day",      as: :day
  get "/agenda/week"     => "agendas#week",     as: :week
  get "/agenda/calendar" => "agendas#calendar", as: :calendar
  get "/agenda/manage"   => "agendas#index",    as: :manage_agenda
  post "/agenda/test_push" => "agendas#test_push", as: :test_push_agenda
  post "/agenda/:id/resync" => "agendas#resync", as: :resync_agenda

  # Resourceful CRUD remapped onto /agenda/* (was /agendas/*). `except: :index`
  # because /agenda/manage above is the index. `except: :show` because there
  # is no "view one agenda" page — the day view shows them all aggregated.
  resources :agendas, path: "agenda", except: [:show, :index] do
    resources :shares, only: [:create, :update, :destroy], controller: :agenda_shares
    resource :notification_setting, only: [:update], controller: :agenda_notification_settings
  end

  # Per-user filter state (hidden agendas, hide-completed, hide-tentative).
  # GET for initial hydrate; PATCH broadcasts the new snapshot to every
  # device the user has open.
  resource :agenda_preference, only: [:show, :update]

  # External-source agenda connection flow (currently: Google Calendar).
  #   `start_google`         — OAuth round-trip kickoff
  #   `new`                  — picker page (CTA if not authed, list of
  #                            calendars with per-row connect/disconnect
  #                            if authed)
  #   `connect_calendar`     — POST: create Agenda for one calendar
  #   `disconnect_calendar`  — DELETE: destroy Agenda + stop watch
  #   `destroy`              — disconnect everything (revoke token + wipe)
  resource :agenda_connection, only: [:new, :destroy]
  scope "agenda_connection", controller: :agenda_connections do
    get    "start/google"         => :start_google,        as: :start_google_agenda_connection
    post   "calendars/connect"    => :connect_calendar,    as: :connect_agenda_connection_calendar
    delete "calendars/disconnect" => :disconnect_calendar, as: :disconnect_agenda_connection_calendar
  end

  # Push-notification receiver for events.watch channels. Google POSTs here
  # whenever a watched calendar changes; the handler enqueues an incremental
  # sync keyed on the X-Goog-Channel-Id header.
  post "webhooks/google_calendar" => "webhooks#google_calendar"

  # Fetch-only endpoints — never navigated to, so they can sit outside the
  # PWA scope without breaking the installed-app experience.
  resources :agenda_items, only: [:create, :update, :destroy] do
    member { post :restore }
  end
  resources :agenda_schedules, only: [:create, :update, :destroy]

  resources :cards, only: [] do
    collection do
      get :deck
    end
  end

  get :random, controller: :random, action: :index
  resources :gcode_splitter, only: [:index]
  resources :colors, only: [:index]
  resources :anonicons, only: [:index, :show], constraints: { id: /[0-9.a-zA-Z]+/ }
  resources :qr_labels, only: [:index, :show]
  get :"svg-editor", controller: :svg_editors, action: :show

  resource :rlcraft, only: [:show, :update]

  resource :little_world, only: [:show] do
    post :save_location
    get :player_login
    get :character_builder
    post :change_clothes
    get :change_clothes, action: :load_character
  end

  namespace :jil do
    get :/, action: :index, controller: :tasks
    get "t/:id" => "tasks#trigger"
    resources :executions, only: [:index, :show] do
      post :replay, on: :member
      get :dashboard, on: :collection
    end
    post "tasks/reorder", to: "tasks#reorder", as: :reorder_tasks
    resources :tasks do
      post :run, on: :member
      post :duplicate, on: :member
      post :shared_users, on: :member
      post :archive, on: :member
      post :unarchive, on: :member
      resources :executions, only: [:index, :show] do
        post :replay, on: :member
        get :dashboard, on: :collection
      end
    end
    resources :task_folders, only: [:create, :update, :destroy] do
      post :toggle_collapsed, on: :member
    end
    resources :user_cache, path: :cache
  end
  get "t/:id" => "jil/tasks#trigger"
  get "jil/p/:id" => "jil/pages#show", as: :jil_page
  get "jil/f/:id" => "jil/forms#show", as: :jil_form
  post "jil/f/:id" => "jil/forms#submit"
  # Must be after `jil` namespace so it doesn't overwrite existing routes
  post "jil/:uuid" => "webhooks#execute_task"
  get "jil/:uuid" => "webhooks#execute_task"

  resources :climbs do
    patch :mark, on: :collection
  end

  namespace :bowling, as: nil do
    resources :bowlers, only: [:create] do
      get :throw_stats, on: :collection
    end
    resources :bowling_leagues, path: :leagues do
      get :tms, on: :member
    end
    resources :bowling_sets, path: :series do
      delete "bowler/:bowler_id", on: :member, action: :remove_bowler
    end
    resources :bowling_games, path: "/"
  end

  resources :contacts, except: :show do
    resources :addresses, except: :show
  end
  resources :folders
  resources :pages, except: :index do
    post :shared_users, on: :member
  end
  get "/pages", to: "folders#index"
  resources :recipes, param: :friendly_id do
    post :export_to_list, on: :member
  end

  resource :maze, only: [:show] do
    collection do
      post ":seed/solve", action: :solve
      match ":seed/solve", action: :preflight, via: :options
      post "/", action: :redirect
      get ".txt", action: "show"
      get ":seed", action: "show"
      get ":seed.txt", action: "show"
    end
  end

  require "sidekiq/web"
  require "sidekiq/cron/web"
  # constraints ->(req) { binding.pry } do
  constraints RoleConstraint.new(:admin) do
    mount ::Sidekiq::Web => "/sidekiq"
    mount ::PgHero::Engine, at: "pghero"
  end

  constraints MeConstraint.new do
    get "/system" => "system#index", as: :system
    get "/system/connections" => "system#connections", as: :system_connections
  end
  mount ::ActionCable.server => "/cable"
end
