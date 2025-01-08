
Rails.application.routes.draw do
  use_doorkeeper

  get "/blockly" => "index#blockly"
  get "/icons" => "index#icons"
  get "/privacy-policy" => "index#privacy_policy"

  constraints subdomain: "sub" do
    get "/sub" => "index#sub"
  end

  get "/jil/tasks/c96939ac-9dc1-4dab-9200-143ac699d5d6/run", to: "webhooks#saya"

  post "tesla/api/1/vehicles/:vin/command/:command" => "vehicles#command"
  post "tesla/oauth2/v3/token" => "vehicles#token"

  root "index#home"
  post "/talk" => "index#talk"
  get "/nest_subscribe" => "index#nest_subscribe"
  post "/jarvis" => "jarvis#command"
  post "proxy" => "proxy#proxy"
  post "/printer_control" => "printers#control"
  get "map" => "index#map"
  get "playground" => "index#playground"
  resource :ping, only: :create

  namespace :api do
    namespace :v1 do
      post :alexa, controller: :alexa
      # resource :alexa, controller: :alexa
    end
  end

  resource :jarvis, only: [:show, :update], controller: :quick_actions, as: :user_dashboard do
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

  post "webhooks/tesla_local" => "webhooks#tesla_local"
  post "jil/trigger/:trigger" => "webhooks#jil"
  post "webhooks/jil" => "webhooks#execute_task"
  get "webhooks/jil" => "webhooks#execute_task"
  post "webhooks/battery" => "webhooks#battery"
  post "webhooks/report" => "webhooks#report"
  get "webhooks/local_ping" => "webhooks#local_ping"
  post "webhooks/local_ping" => "webhooks#local_ping"
  post "webhooks/jenkins" => "webhooks#jenkins"
  post "webhooks/post" => "webhooks#post"
  post "webhooks/google_pub_sub" => "webhooks#google_pub_sub"
  post "webhooks/email" => "webhooks#email"
  post "webhooks/speak" => "webhooks#speak"
  post "webhooks/notify" => "webhooks#notify"
  get "webhooks/uptime" => "webhooks#uptime"
  post "webhooks/uptime" => "webhooks#uptime"
  post "webhooks/command" => "webhooks#command"
  get "webhooks/auth" => "webhooks#auth"
  get "webhooks/auth/:service" => "webhooks#auth"
  get "webhooks/oauth/:service" => "webhooks#auth"
  post "push_notification_subscribe" => "webhooks#push_notification_subscribe"

  get "dashboard" => "dashboard#show"
  resource :dashboard, controller: :dashboard, only: [:show] do
    get :demo, on: :collection
    collection do
      get :octoprint_session
    end
  end

  resource :nfc, only: [:show]

  resources :emails, except: [:destroy, :edit]
  resources :log_trackers, only: [:index, :show ]
  post "/ips/ban" => "log_trackers#ban", as: :ban_ip

  resources :surveys
  resources :survey_responses

  resource :calc, only: [:show]

  resources :action_events do
    get :calendar, on: :collection
    get :pullups, on: :collection
    get :feelings, on: :collection
  end

  resource :summoners_war do
    get :runes
    resources :monsters
    resources :monster_skills
  end

  get :account, controller: :users
  resources :api_keys, except: :show
  resources :users, only: [ :new, :create, :update ]
  resources :lists do
    post :reorder, on: :collection
    member do
      post :modify_from_message
      post :receive_update
    end
    resources :user_lists, only: [:index, :create, :destroy], path: :users
    resources :list_items
  end

  resources :cards, only: [] do
    collection do
      get :deck
    end
  end

  get :random, controller: :random, action: :index
  resources :gcode_splitter, only: [ :index ]
  resources :colors, only: [ :index ]
  resources :anonicons, only: [ :index, :show ], constraints: { id: /[0-9.a-zA-Z]+/ }
  get :"svg-editor", controller: :svg_editors, action: :show

  resource :rlcraft, only: [:show, :update]

  resource :little_world, only: [ :show ] do
    post :save_location
    get :player_login
    get :character_builder
    post :change_clothes
    get :change_clothes, action: :load_character
  end

  namespace :jil do
    get :/, action: :index, controller: :tasks
    resources :tasks do
      post :run, on: :member
    end
    resources :user_cache, path: :cache
  end
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
  resources :pages, except: :index
  get "/pages", to: "folders#index"
  resources :recipes, param: :friendly_id do
    post :export_to_list, on: :member
  end

  resource :maze, only: [ :show ] do
    collection do
      post "/", action: :redirect
      get ".txt", action: "show"
      get ":seed", action: "show"
      get ":seed.txt", action: "show"
    end
  end

  require "sidekiq/web"
  # constraints ->(req) { binding.pry } do
  constraints RoleConstraint.new(:admin) do
    mount ::Sidekiq::Web => "/sidekiq"
    mount ::PgHero::Engine, at: "pghero"
  end
  mount ::ActionCable.server => "/cable"
end
