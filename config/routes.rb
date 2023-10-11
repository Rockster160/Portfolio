Rails.application.routes.draw do
  mount ::CommandProposal::Engine => "/commands"

  get "/blockly" => "index#blockly"
  get "/icons" => "index#icons"

  constraints subdomain: "sub" do
    get "/sub" => "index#sub"
  end

  root "index#home"
  post "/talk" => "index#talk"
  get "/nest_subscribe" => "index#nest_subscribe"
  post "/jarvis" => "jarvis#command"
  post "proxy" => "proxy#proxy"
  post "/printer_control" => "printers#control"
  get "map" => "index#map"
  get "playground" => "index#playground"
  resource :ping, only: :create

  resource :jarvis, only: :show, controller: :quick_actions
  resources :jil_prompts, only: [:index, :show, :update], path: :prompts

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

  resources :functions do
    post :run
  end

  resource :money_buckets, path: "/bucket"

  post "webhooks/tesla_local" => "webhooks#tesla_local"
  post "webhooks/jil" => "webhooks#jil"
  post "webhooks/battery" => "webhooks#battery"
  post "webhooks/report" => "webhooks#report"
  post "webhooks/local_data" => "webhooks#local_data"
  post "webhooks/jenkins" => "webhooks#jenkins"
  post "webhooks/post" => "webhooks#post"
  post "webhooks/google_pub_sub" => "webhooks#google_pub_sub"
  post "webhooks/email" => "webhooks#email"
  post "webhooks/speak" => "webhooks#speak"
  post "webhooks/notify" => "webhooks#notify"
  get "webhooks/uptime" => "webhooks#uptime"
  post "webhooks/uptime" => "webhooks#uptime"
  post "webhooks/command" => "webhooks#command"
  post "webhooks/auth" => "webhooks#auth"
  post "webhooks/auth/:service" => "webhooks#auth"
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
  resources :log_trackers, only: [ :index, :show ]

  resources :surveys
  resources :survey_responses

  resource :calc, only: [:show]

  resources :action_events do
    get :calendar, on: :collection
    get :pullups, on: :collection
  end

  resource :summoners_war do
    get :runes
    resources :monsters
    resources :monster_skills
  end

  get :account, controller: :users
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

  resources :jarvis_tasks, path: :tasks
  resources :scheduled_tasks, path: :scheduled, param: :uid, only: [:index, :create, :update, :destroy]
  namespace :jil do
    get :/, action: :index, controller: :jarvis_tasks
    resources :jarvis_tasks, path: :tasks do
      get :config, on: :member, action: :configuration
      get :run, on: :member
      post :run, on: :member
      post :duplicate, on: :member
    end
  end

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
    resources :bowling_sets, path: :series
    resources :bowling_games, path: "/"
  end

  resources :contacts
  resources :folders
  resources :pages, except: :index
  resources :recipes, param: :friendly_id do
    post :export_to_list, on: :member
  end

  resource :maze, only: [ :show ] do
    collection do
      get ".txt", action: "show"
      get ":seed", action: "show"
      get ":seed.txt", action: "show"
    end
  end

  resources :venmos, only: [:index], path: "venmo" do
    collection do
      get "auth"
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
