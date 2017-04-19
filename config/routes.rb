Rails.application.routes.draw do

  root 'index#home'
  post '/talk' => 'index#talk'
  get 'map' => 'index#map'

  post 'webhooks/:action', as: :webhooks, controller: 'webhooks'

  resources :lists, only: [ :index ] do
    collection do
      get ":list_name", action: :show, constraints: lambda { |request| List.pluck(:name).map(&:parameterize).include?(request.path_parameters[:list_name]) }
    end
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

end
