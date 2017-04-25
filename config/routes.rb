Rails.application.routes.draw do

  root 'index#home'
  post '/talk' => 'index#talk'
  get 'map' => 'index#map'

  get 'login' => 'users/sessions#new'
  post 'login' => 'users/sessions#create'
  get 'register' => 'users/registrations#new'
  post 'register' => 'users/registrations#create'
  patch 'register' => 'users/registrations#create'
  get 'logout' => 'users/sessions#destroy'
  delete 'logout' => 'users/sessions#destroy'

  post 'webhooks/:action', as: :webhooks, controller: 'webhooks'

  resources :users, only: [ :new, :create ]
  resources :lists, except: [ :edit, :update ] do
    post :update, on: :member
    resources :list_items, only: [ :create, :destroy ]
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

  # Websockets
  mount ActionCable.server => '/cable'

end
