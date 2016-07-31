class PokemonScannerWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(pokewalker_id, coords)
    walker = Pokewalker.find(pokewalker_id)
    return nil if walker.nil?
    walker.login

    walker.search_coords(coords, 0.1)
  end

end
