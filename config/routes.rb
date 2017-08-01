Rails.application.routes.draw do

  root 'index#home'
  post '/talk' => 'index#talk'
  get 'map' => 'index#map'
  get 'playground' => 'index#playground'

  get 'login' => 'users/sessions#new'
  post 'login' => 'users/sessions#create'
  get 'register' => 'users/registrations#new'
  post 'register' => 'users/registrations#create'
  patch 'register' => 'users/registrations#create'
  get 'logout' => 'users/sessions#destroy'
  delete 'logout' => 'users/sessions#destroy'

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
    post :receive_update, on: :member
    get :users, on: :member
    resources :list_items, only: [ :create, :destroy ]
  end

  resources :cards, only: [] do
    collection do
      get :deck
    end
  end

  resources :colors, only: [ :index ]
  resources :anonicons, only: [ :index, :show ]

  resource :little_world, only: [ :show ] do
    post :save_location
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
