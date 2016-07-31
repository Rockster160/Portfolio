class Pokeapi
  include CoordCalculator
  attr_accessor :client, :lat, :lng

  def self.login(user)
    pk = new
    pk.login(user)
    pk
  end

  def login(user)
    @client = Poke::API::Client.new
    begin
      @client.login(user.username, user.password, 'ptc')
    rescue Poke::API::Errors::LoginFailure => e
      puts "\e[31m Failed to login: #{e}\e[0m"
    end
  end

  def scan(loc=[@lat,@lng], options={})
    radius = options[:radius] || 2
    distance_per_block = options[:distance_per_block] || 0.0005
    delay = options[:delay] || 0.5
    loc = goto('home') if loc.compact.empty?
    loc = loc.is_a?(String) ? loc.split(',') : loc
    lat, lng = loc.map(&:to_f)
    coords = get_actual_coords_from_spiral(radius, distance_per_block, [lat, lng])
    search_coords(coords, delay)
  end

  def get_actual_coords_from_spiral(radius, distance_per_block, origin); Pokeapi.get_actual_coords_from_spiral(radius, distance_per_block, origin); end
  def self.get_actual_coords_from_spiral(radius, distance_per_block, origin)
    lat, lng = origin
    relative_coords = spiral_coords(radius)
    relative_coords.map { |x, y| [lat + (x * distance_per_block), lng + (y * distance_per_block)] }
  end

  def search_coords(coords, delay=0.5)
    pokemon_found = []
    coords.each do |new_lat, new_lng|
      sleep delay
      goto("#{new_lat},#{new_lng}")
      pokemon_found += search
    end
    pokemon_found
  end

  def spiral_coords(radius); Pokeapi.spiral_coords(radius); end
  def self.spiral_coords(radius)
    width = (radius * 2) + 1
    steps = width ** 2
    (0...steps).map do |i|
      j = Math.sqrt(i).round
      k = (j ** 2 - i).abs - j
      coord = [k, -k].map { |l| (l + j ** 2 - i - (j % 2)) * 0.5 * (-1) ** j }.map(&:to_i)
      coord
    end
  end

  def my_loc; [lat, lng]; end
  def from_lat; lat; end
  def from_lng; lng; end

  def goto(location)
    return nil unless location
    location = location.is_a?(String) ? location : location.join(',')
    loc = case location
    when 'home' then '40.53807962696459,-111.97943799266993'
    when 'office' then '40.57031218969614,-111.89489496028821'
    else location
    end
    coord_str = loc.split(',')
    if coord_str.present? && coord_str.length == 2 && coord_str.map(&:to_f).map(&:to_s) == coord_str
      @client.lat, @client.lng = coord_str.map(&:to_f)
    else
      @client.store_location(loc)
    end
    [@lat = @client.lat, @lng = @client.lng]
  end

  def search
    begin
      get_pokemon(call_python)
    rescue
      Rails.logger.error "Failed to call Python!"
      []
    end
  end

  def call_python
    cell_id_string_list = `python -c 'from get_cell_id import get_cell_ids; print(get_cell_ids(#{@client.lat},#{@client.lng}, 15))'`
    cell_ids = cell_id_string_list.tr('[L]', '').split.map(&:to_i)
    map_objects = @client.get_map_objects(latitude: @client.lat, longitude: @client.lng, since_timestamp_ms: [0] * cell_ids.length, cell_id: cell_ids)
    response = @client.call
  end

  def get_pokemon(search_results)
    return ["No Response"] unless search_results.response.present?
    return ["No Map"] unless search_results.response[:GET_MAP_OBJECTS].present?
    return ["No Status"] unless search_results.response[:GET_MAP_OBJECTS][:status].present?
    return ["No Cells"] unless search_results.response[:GET_MAP_OBJECTS][:map_cells].present?
    map_cells = search_results.response[:GET_MAP_OBJECTS][:map_cells]
    relevant_data = map_cells.map { |cell| cell.extract!(:wild_pokemons) }.reject { |cell| cell[:wild_pokemons].empty? }
    pokemon_found = []
    relevant_data.each do |wild_pokemons|
      wild_pokemons[:wild_pokemons].each do |wild_pokemon|
        expires_in_seconds = (wild_pokemon[:time_till_hidden_ms].to_f / 1000.to_f).seconds
        expires_at = DateTime.current + expires_in_seconds
        poke_id, name = Pokedex.id_and_name_by_id_or_name(wild_pokemon[:pokemon_data][:pokemon_id].to_s)
        pokemon = Pokemon.create(
          pokedex_id: poke_id.to_s,
          lat: wild_pokemon[:latitude].to_s,
          lng: wild_pokemon[:longitude].to_s,
          name: name,
          expires_at: expires_at
        )
        puts "\e[31m Pokemon! #{pokemon.name} \e[0m"
        if pokemon.persisted?
          puts "\e[31m Saved! \e[0m"
          pokemon_found << pokemon
        end
      end
    end
    pokemon_found
  end

end
