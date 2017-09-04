Rails.application.routes.draw do

  root 'index#home'
  post '/talk' => 'index#talk'
  get 'map' => 'index#map'
  get 'playground' => 'index#playground'

  scope module: :users do
    get :login,      controller: :sessions,      action: :new
    post :login,     controller: :sessions,      action: :create
    get :logout,     controller: :sessions,      action: :destroy
    delete :logout,  controller: :sessions,      action: :destroy
    get :register,   controller: :registrations, action: :new
    post :register,  controller: :registrations, action: :create
    patch :register, controller: :registrations, action: :create
  end

  post 'webhooks/jenkins' => "webhooks#jenkins"
  post 'webhooks/post' => "webhooks#post"

  get 'cube' => 'cubes#show'

  resources :log_trackers, only: [ :index, :show ]

  resource :summoners_war do
    resources :monsters
    resources :monster_skills
  end

  get :account, controller: :users
  resources :users, only: [ :new, :create, :update ]
  resources :lists do
    member do
      post :modify_from_message
      post :receive_update
      get :users
    end
    resources :list_items, only: [ :create, :destroy ]
  end

  resources :cards, only: [] do
    collection do
      get :deck
    end
  end

  resources :colors, only: [ :index ]
  resources :anonicons, only: [ :index, :show ], constraints: { id: /[0-9.a-zA-Z]+/ }

  resource :little_world, only: [ :show ] do
    post :save_location
    get :player_login
    get :character_builder
    post :change_clothes
    get :change_clothes, action: :load_character
  end

  resources :mazes, only: [ :index ] do
    collection do
      get 'random', action: 'random'
      get ':seed', action: 'random'
      get 'random.txt', action: 'random'
    end
  end

  resources :venmos, path: 'venmo' do
    collection do
      get 'auth'
    end
  end

  require 'sidekiq/web'
  mount Sidekiq::Web => '/sidekiq'
  mount ActionCable.server => '/cable'

end
