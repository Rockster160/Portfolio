Rails.application.routes.draw do

  root 'index#home'
  get 'search/index'
  get '/search' => 'search#index'
  get 'batch/index'
  get 'flashcard/:type/:old' => 'index#flashcard', as: 'flashcard'
  post '/talk' => 'index#talk'
  get 'playground' => 'index#play', as: 'playground'
  get 'pokemon' => 'pokemon#index'
  post 'pokemon' => 'pokemon#locations'
  post 'scan' => 'pokemon#scan'

  require 'sidekiq/web'
  mount Sidekiq::Web => '/sidekiq'

end
