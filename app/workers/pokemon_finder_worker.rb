class PokemonFinderWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform(loc)
    lat, lng = loc.split(',').map(&:to_f)
    users = Pokewalker.where(monitor_loc_start: nil).where(monitor_loc_end: nil)
    coords = Pokeapi.get_actual_coords_from_spiral(4, 0.0005, [lat, lng])

    coords.in_groups(users.count, false).each_with_index do |walker_coords, idx|
      PokemonScannerWorker.perform_async(users[idx].id, walker_coords)
    end
  end

end
