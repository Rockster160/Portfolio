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

  def login(should_goto=false)
    @pk = Pokeapi.login(self)
    @pk.goto(last_loc) if last_loc && should_goto
    @pk
  end

  def goto(loc)
    return 'Not logged in' unless @pk
    new_loc = @pk.goto(loc)
    update(last_loc: new_loc.join(',')) if new_loc.length == 2
  end

  def walk_to(loc, options={})
    distance_per_block = options[:distance_per_block] || 0.001
    return 'Not logged in' unless @pk
    return 'No location found' unless last_loc.present?
    coord_list = get_coords_between_points(loc, last_loc, distance_per_block)
    coord_list.each do |coord|
      sleep 0.2
      goto(coord)
      check
    end
  end

  def search_coords(coords, delay=0.5)
    return 'Not logged in' unless @pk
    @pk.search_coords(coords, delay=0.5)
  end

  def check
    return 'Not logged in' unless @pk
    return 'No location found' unless last_loc.present?
    @pk.scan(last_loc.split(','), {radius: 1, delay: 0.1})
  end

end
# w = Pokewalker.all.sample; w.login; w.goto('40.54420461739111,-111.98411609064698'); w.walk_to('40.53696445738481,-111.97682048212647')
# w = Pokewalker.last; w.login; w.goto('home'); w.check
# w.goto('40.53855759476969,-111.97707046770631')
# w.walk_to('40.544167022982016,-111.98406566881715')
