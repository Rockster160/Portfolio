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
  include CoordCalculator

  validate :not_duplicate
  validates :name, :pokedex_id, presence: true

  # scope :spawned, -> { where(nil) }
  scope :spawned, -> { where('expires_at > ?', DateTime.current) }
  def self.sort_by_distance(loc)
    spawned.sort_by { |pk| distance_between(loc, pk.location) }
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

  def location
    [lat.to_f, lon.to_f]
  end

  def relative_directions(to_loc)
    directions(location, to_loc)
  end

  def relative_bearing(to_loc)
    bearing(location, to_loc)
  end

  def time_until_expired
    time_in_words = time_ago_in_words(expires_at)
    if expires_at < DateTime.current
      "#{time_in_words} ago"
    else
      "#{time_in_words} from now"
    end
  end

  private

  def not_duplicate
    dups = Pokemon.where(pokedex_id: pokedex_id).where(lat: lat).where(lon: lon).where(expires_at: (expires_at - 30.seconds)..(expires_at + 30.seconds))
    if dups.any?
      errors.add(:base, "This Pokemon has already been added.")
    end
  end

end
