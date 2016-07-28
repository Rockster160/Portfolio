class Pokeapi
  include CoordCalculator
  attr_accessor :client, :lat, :lon

  def login
    @client = Poke::API::Client.new
    @client.login('Caitherra', 'password', 'ptc')
  end

  def scan_area(loc=[@lat,@lon], radius=2)
    distance_per_block = 0.0005
    lat, lon = loc
    coords = spiral_coords(radius)
    coords.each do |x, y|
      sleep 0.5
      new_lat = lat + (x * distance_per_block)
      new_lon = lon + (y * distance_per_block)
      puts "Scanning (#{new_lat},#{new_lon})"
      goto("#{new_lat},#{new_lon}")
      search
    end
  end

  def spiral_coords(radius)
    width = (radius * 2) + 1
    steps = width ** 2
    (0...steps).map do |i|
      j = Math.sqrt(i).round
      k = (j ** 2 - i).abs - j
      coord = [k, -k].map { |l| (l + j ** 2 - i - (j % 2)) * 0.5 * (-1) ** j }.map(&:to_i)
      coord
    end
  end

  def my_loc; [lat, lon]; end
  def from_lat; lat; end
  def from_lon; lon; end

  def goto(location)
    loc = case location
    when 'home' then '40.53807962696459,-111.97943799266993'
    when 'office' then '40.57031218969614,-111.89489496028821'
    else location
    end
    @client.store_location(loc)
    [@lat = @client.lat, @lon = @client.lng]
  end

  def search
    get_pokemon(call_python)
  end

  def call_python
    cell_id_string_list = `python -c 'from get_cell_id import get_cell_ids; print(get_cell_ids(#{@client.lat},#{@client.lng}, 15))'`
    cell_ids = cell_id_string_list.tr('[L]', '').split.map(&:to_i)
    map_objects = @client.get_map_objects(latitude: @client.lat,longitude: @client.lng,since_timestamp_ms: [0] * cell_ids.length,cell_id: cell_ids)
    response = @client.call
  end

  def get_pokemon(search_results)
    return logger.error("No Response") unless search_results.response.present?
    return logger.error("No Map") unless search_results.response[:GET_MAP_OBJECTS].present?
    return logger.error("No Status") unless search_results.response[:GET_MAP_OBJECTS][:status].present?
    return logger.error("No Cells") unless search_results.response[:GET_MAP_OBJECTS][:map_cells].present?
    map_cells = search_results.response[:GET_MAP_OBJECTS][:map_cells]
    relevant_data = map_cells.map { |cell| cell.extract!(:wild_pokemons) }.reject { |cell| cell[:wild_pokemons].empty? }
    relevant_data.each do |wild_pokemons|
      wild_pokemons[:wild_pokemons].each do |wild_pokemon|
        expires_in_seconds = (wild_pokemon[:time_till_hidden_ms].to_f / 1000.to_f).seconds
        expires_at = DateTime.current + expires_in_seconds
        poke_id, name = Pokedex.id_and_name_by_id_or_name(wild_pokemon[:pokemon_data][:pokemon_id].to_s)
        Pokemon.create(
          pokedex_id: poke_id.to_s,
          lat: wild_pokemon[:latitude].to_s,
          lon: wild_pokemon[:longitude].to_s,
          name: name,
          expires_at: expires_at
        )
      end
    end
  end

  def self.login_and_scan
    pk = Pokeapi.new
    pk.login
    pk.goto('home')
    pk.scan_area
    pk
  end

end
