Rails.application.routes.draw do
  constraints subdomain: "sub" do
    get "/sub" => "index#sub"
  end

  root "index#home"
  post "/talk" => "index#talk"
  get "map" => "index#map"
  get "playground" => "index#playground"

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

  post "webhooks/jenkins" => "webhooks#jenkins"
  post "webhooks/post" => "webhooks#post"
  post "webhooks/email" => "webhooks#email"
  post "webhooks/command" => "webhooks#command"
  post "push_notification_subscribe" => "webhooks#push_notification_subscribe"

  get "cube" => "cubes#show"

  resource :nfc, only: [:show]

  resources :emails, except: [:destroy, :edit]
  resources :log_trackers, only: [ :index, :show ]

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

  resources :venmos, path: "venmo" do
    collection do
      get "auth"
    end
  end

  require "sidekiq/web"
  mount Sidekiq::Web => "/sidekiq"
  mount ActionCable.server => "/cable"
end
