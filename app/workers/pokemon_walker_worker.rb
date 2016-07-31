class PokemonWalkerWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    Pokewalker.where.not(monitor_loc_start: nil).where.not(monitor_loc_end: nil).shuffle.each do |walker|
      walker.login
      walker.walk_to(walker.monitor_loc_start)
      walker.walk_to(walker.monitor_loc_end)
    end
  end

end
