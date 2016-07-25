# == Schema Information
#
# Table name: pokemons
#
#  id         :integer          not null, primary key
#  pokedex_id :integer
#  lat        :string(255)
#  lon        :string(255)
#  name       :string(255)
#  expires_at :datetime
#  created_at :datetime
#  updated_at :datetime
#

class Pokemon < ActiveRecord::Base
  require 'action_view'
  include ActionView::Helpers::DateHelper

  validate :not_duplicate

  # scope :spawned, -> { where(nil) }
  scope :spawned, -> { where('expires_at > ?', DateTime.current) }
  def self.sort_by_distance(loc)
    spawned.sort_by { |pk| Pokemon.distance_between(loc, pk.location) }
  end

  def self.last_update
    last_poke_updated_at = order(updated_at: :desc).last.try(:updated_at)
    last_poke_created_at = order(created_at: :desc).last.try(:created_at)
    [last_poke_updated_at, last_poke_created_at].compact.sort.last
  end

  def self.add_from_python_str(str)
    # "74:40.539857,-111.978192:653028"
    poke_id, lat_lon_str, expires_in_ms = str.split(":")
    poke_loc = lat_lon_str.split(',')
    expires_at = DateTime.current + (expires_in_ms.to_i / 1000).seconds
    add(poke_id, poke_loc, expires_at)
  end

  def self.add(poke_id, loc, expires_at=10.minutes.from_now)
    pokemon = Pokemon.new
    pokemon.pokedex_id = poke_id.to_i
    pokemon.expires_at = expires_at
    pokemon.name = Pokedex.name_by_id(pokemon.pokedex_id)
    pokemon.lat, pokemon.lon = loc.map(&:to_s) if loc.present?
    pokemon.save
    pokemon
  end

  def self.distance_between(loc1, loc2)
    loc1, loc2 = loc1.map(&:to_f), loc2.map(&:to_f)
    rad_per_deg = Math::PI/180
    rkm = 6371                  # Earth radius in kilometers
    rm = rkm * 1000             # Radius in meters

    dlat_rad = (loc2[0]-loc1[0]) * rad_per_deg  # Delta, converted to rad
    dlon_rad = (loc2[1]-loc1[1]) * rad_per_deg

    lat1_rad, lon1_rad = loc1.map {|i| i * rad_per_deg }
    lat2_rad, lon2_rad = loc2.map {|i| i * rad_per_deg }

    a = Math.sin(dlat_rad/2)**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * Math.sin(dlon_rad/2)**2
    c = 2 * Math::atan2(Math::sqrt(a), Math::sqrt(1-a))

    meters = rm * c
    feet = meters * 3.28084
  end

  def location
    [lat.to_f, lon.to_f]
  end

  def directions(from_loc)
    calc_cardinal_direction(from_loc)
  end

  def bearing(from_loc)
    brng = calc_bearing(from_loc)
    dist = Pokemon.distance_between(from_loc, location)
    "#{brng.round(2)}º #{dist.round(2)}ft"
  end

  def time_until_expired
    time_in_words = time_ago_in_words(expires_at)
    if expires_at < DateTime.current
      "#{time_in_words} ago"
    else
      "#{time_in_words} from now"
    end
  end

  def calc_cardinal_direction(from_loc)
    from_lat, from_lon = from_loc
    to_lat, to_lon = location
    # N = + Lat
    # E = + Lon
    # S = - Lat
    # W = - Lon
    lat_distance = Pokemon.distance_between([from_lat, from_lon], [to_lat, from_lon])
    lon_distance = Pokemon.distance_between([from_lat, from_lon], [from_lat, to_lon])
    lat_cardinal_direction = from_lat < to_lat ? 'N' : 'S'
    lon_cardinal_direction = from_lon < to_lon ? 'E' : 'W'
    lat_distance_str = "#{lat_distance.round(2)}ft #{lat_cardinal_direction}"
    lon_distance_str = "#{lon_distance.round(2)}ft #{lon_cardinal_direction}"
    [lat_distance_str, lon_distance_str].join(', ')
  end

  def calc_bearing(from_loc)
    from_lat, from_lon = from_loc
    to_lat, to_lon = location
    delta_lon = (from_lon - to_lon)

    y = Math.sin(delta_lon) * Math.cos(to_lat)
    x = Math.cos(from_lat) * Math.sin(to_lat) - Math.sin(from_lat) * Math.cos(to_lat) * Math.cos(delta_lon)

    brng = Math.atan2(y, x)

    brng = to_deg(brng)
    brng = (brng + 360) % 360
    brng = 360 - brng

    return brng# º
  end

  def to_deg(rad)
    (180 / Math::PI) * rad
  end
  def to_rad(ang)
    (ang/180) * Math::PI
  end

  private

  def not_duplicate
    dups = Pokemon.where(pokedex_id: pokedex_id).where(lat: lat).where(lon: lon).where(expires_at: (expires_at - 30.seconds)..(expires_at + 30.seconds))
    if dups.any?
      errors.add(:base, "This Pokemon has already been added.")
    end
  end

end
