Rails.application.routes.draw do
  mount ::CommandProposal::Engine => "/commands"

  constraints subdomain: "sub" do
    get "/sub" => "index#sub"
  end

  root "index#home"
  post "/talk" => "index#talk"
  post "/nest_subscribe" => "index#nest_subscribe"
  post "/jarvis" => "jarvis#command"
  post "proxy" => "proxy#proxy"
  post "/printer_control" => "printers#control"
  get "map" => "index#map"
  get "playground" => "index#playground"
  resource :ping, only: :create

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

  post "webhooks/report" => "webhooks#report"
  post "webhooks/local_data" => "webhooks#local_data"
  post "webhooks/jenkins" => "webhooks#jenkins"
  post "webhooks/post" => "webhooks#post"
  post "webhooks/google_pub_sub" => "webhooks#google_pub_sub"
  post "webhooks/email" => "webhooks#email"
  post "webhooks/speak" => "webhooks#speak"
  post "webhooks/notify" => "webhooks#notify"
  post "webhooks/command" => "webhooks#command"
  post "push_notification_subscribe" => "webhooks#push_notification_subscribe"

  get "dashboard" => "dashboard#show"
  resource :dashboard, controller: :dashboard, only: [:show] do
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

  resources :action_events

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

  resources :venmo_recurrings, path: :venmo_charges

  require "sidekiq/web"
  # constraints ->(req) { binding.pry } do
  constraints RoleConstraint.new(:admin) do
    mount Sidekiq::Web => "/sidekiq"
  end
  mount ActionCable.server => "/cable"
end
