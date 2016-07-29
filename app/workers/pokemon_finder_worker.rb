class PokemonFinderWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(loc)
    lat, lng = loc.split(',')
    pk = Pokeapi.login
    pk.scan([lat, lng])
  end

end
