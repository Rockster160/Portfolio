class PokemonFinderWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(loc)
    lat, lng = loc.split(',')
    pk = Pokeapi.login(Pokewalker.all.sample)
    pk.scan([lat, lng])
  end

end
