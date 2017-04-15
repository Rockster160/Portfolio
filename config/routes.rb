Rails.application.routes.draw do

  root 'index#home'
  get 'search/index'
  get '/search' => 'search#index'
  get 'batch/index'
  get 'flashcard/:type/:old' => 'index#flashcard', as: 'flashcard'
  post '/talk' => 'index#talk'
  get 'playground' => 'index#play', as: 'playground'

  get 'map' => 'index#map'

  # get 'pokemon' => 'pokemon#index'
  # post 'scan' => 'pokemon#scan'
  # get 'pokemon_list' => 'pokemon#pokemon_list'

  post 'webhooks/:action', as: :webhooks, controller: 'webhooks'

  resources :lists, only: [ :index ] do
    collection do
      get ":list_name", action: :show, constraints: lambda { |request| List.pluck(:name).map(&:parameterize).include?(request.path_parameters[:list_name]) }
    end
    resources :list_items, only: [ :create, :destroy ]
  end

  resources :mazes, only: [] do
    collection do
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
