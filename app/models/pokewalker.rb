# == Schema Information
#
# Table name: pokewalkers
#
#  id                :integer          not null, primary key
#  username          :string(255)
#  password          :string(255)
#  last_loc          :string(255)
#  banned            :boolean          default(FALSE)
#  monitor_loc_start :string(255)
#  monitor_loc_end   :string(255)
#  created_at        :datetime
#  updated_at        :datetime
#

class Pokewalker < ActiveRecord::Base
  include CoordCalculator
  attr_accessor :pk

  def login
    @pk = Pokeapi.login(self)
  end

  def goto(loc)
    return 'Not logged in' unless @pk
    @pk.goto(loc)
  end

  def walk_to(loc, options={})
    distance_per_block = options[:distance_per_block] || 0.001
    return 'Not logged in' unless @pk
    return 'No location found' unless last_loc.present?
    coord_list = get_coords_between_points(loc, last_loc, distance_per_block)
    coord_list.each do |coord|
      sleep 0.1
      goto(coord)
      check
    end
  end

  def check
    return 'Not logged in' unless @pk
    return 'No location found' unless last_loc.present?
    @pk.scan(last_loc.split(','), {delay: 0.1})
  end

end
# w = Pokewalker.last; w.login; w.goto('home'); w.check
# w.goto('40.53855759476969,-111.97707046770631')
# w.walk_to('40.544167022982016,-111.98406566881715')
