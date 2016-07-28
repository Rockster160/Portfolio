class PokemonController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @pokemon = Pokemon.spawned
    lat = params[:lat] || 40.53793474945806
    lon = params[:lon] || -111.97962070833802
    @location = [lat, lon]
  end

  def pokemon_list
    @pokemon = Pokemon.spawned
    respond_to do |format|
      format.html { render layout: !request.xhr? }
    end
  end

  def recently_updated
    updating_response = {still_updating: still_updating?, last_updated: Pokemon.last_update.to_i}

    respond_to do |format|
      format.json { render json: updating_response }
    end
  end

  def scan
    # lat = 40.53793474945806
    # lon = -111.97962070833802
    PokemonFinderWorker.perform_async(params[:loc])
    respond_to do |format|
      format.json { render nothing: true }
    end
  end

  def locations
    Rails.logger.info params
    list = params['nearby']
    my_loc = params['from'].split(',')
    # my_loc = [40.53796850822244,-111.97944975576598]
    already_found = []
    pokemon = []
    list.split('|').each do |nearby|
      next unless nearby.length > 0
      without_timestamp = nearby.split(":").first(2)
      next if already_found.include?(without_timestamp)
      already_found << without_timestamp
      poke = Pokemon.add_from_python_str(nearby)
      pokemon << poke
    end
    puts "\e[33m(#{my_loc.join(',')})"
    pokemon.sort_by { |pk| Pokemon.sort_by_distance(my_loc) }.each do |poke|
      puts "#{poke.pokedex_id} - #{poke.name}"
      puts "     #{poke.location.join(', ')}"
      puts "     #{poke.relative_directions(my_loc.map(&:to_f))}"
      puts "     #{poke.relative_bearing(my_loc.map(&:to_f))}"
    end
    puts "\e[0m"
    head 200
  end

  private

  def still_updating?
    ps = Sidekiq::ProcessSet.new
    ps.map { |process| process['busy'].to_i }.sum > 0
  end

end
