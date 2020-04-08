# == Schema Information
#
# Table name: rlcraft_map_locations
#
#  id            :integer          not null, primary key
#  x_coord       :integer
#  y_coord       :integer
#  title         :string
#  location_type :string
#  description   :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#

class RlcraftMapLocation < ApplicationRecord
  def self.graphable_data
    find_each.map do |location|
      location.to_graphable_data
    end
  end

  def self.location_types
    [
      "Waystone",
      "Book",
      "Player Base",
      "Black Dragon",
      "Red Dragon",
      "Green Dragon",
      "White Dragon",
      "Blue Dragon",
      "Other"
    ]
  end

  def to_graphable_data
    {
      id: id,
      x: x_coord,
      y: y_coord,
      type: location_type.presence,
      title: title.presence,
      description: description.presence,
      removed: destroyed?
    }
  end
end
