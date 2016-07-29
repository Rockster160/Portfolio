# == Schema Information
#
# Table name: pokemons
#
#  id         :integer          not null, primary key
#  pokedex_id :integer
#  lat        :string(255)
#  lng        :string(255)
#  name       :string(255)
#  expires_at :datetime
#  created_at :datetime
#  updated_at :datetime
#

class Pokemon < ActiveRecord::Base
  require 'action_view'
  include CoordCalculator

  validate :not_duplicate
  validates :name, :pokedex_id, presence: true

  scope :spawned, -> { where('expires_at > ?', DateTime.current) }
  scope :since, lambda { |datetime| where('updated_at > ?', datetime) }

  def location
    [lat.to_f, lng.to_f]
  end

  private

  def not_duplicate
    dups = Pokemon.where(pokedex_id: pokedex_id).where(lat: lat).where(lng: lng).where(expires_at: (expires_at - 30.seconds)..(expires_at + 30.seconds))
    if dups.any?
      errors.add(:base, "This Pokemon has already been added.")
    end
  end

end
