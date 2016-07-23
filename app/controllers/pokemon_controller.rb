class PokemonController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @location = params[:loc].present? ? params[:loc].split(',') : [40.53796850822244,-111.97944975576598]
    @pokemon = Pokemon.sort_by_distance(@location)
  end

  def scan
    # lat = 40.53793474945806
    # lon = -111.97962070833802
    result = `python2 pogo/demo.py -a ptc -u Caitherra -p password --location "#{params[:lat]},#{params[:lon]}"`
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
    pokemon.sort_by {|pk|Pokemon.distance_between(my_loc, pk.location)}.each do |poke|
      puts "#{poke.pokedex_id} - #{poke.name}"
      puts "     #{poke.location.join(', ')}"
      puts "     #{poke.directions(my_loc.map(&:to_f))}"
      puts "     #{poke.bearing(my_loc.map(&:to_f))}"
    end
    puts "\e[0m"
    head 200
  end

end
