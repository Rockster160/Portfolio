Rails.application.routes.draw do

  root 'index#home'
  get 'search/index'
  get '/search' => 'search#index'
  get 'batch/index'
  get 'flashcard/:type/:old' => 'index#flashcard', as: 'flashcard'
  post '/talk' => 'index#talk'
  get 'playground' => 'index#play', as: 'playground'

  get 'pokemon' => 'pokemon#index'
  post 'scan' => 'pokemon#scan'
  get 'pokemon_list' => 'pokemon#pokemon_list'

  require 'sidekiq/web'
  mount Sidekiq::Web => '/sidekiq'

end
