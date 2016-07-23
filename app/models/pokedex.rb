require 'csv'
class Pokedex
  attr_reader :pokelist

  def self.pokelist
    list = []
    CSV.foreach('pokedex.csv') do |row|
      list << row
    end
    list
  end

  def self.name_by_id(id)
    pokelist[id.to_i - 1].try(:last)
  end

  def dostuff
    pk = Poke::API::Client.new
    pk.login('Caitherra', 'password', 'ptc')
    # 40.53807962696459,-111.97943799266993
    pk.store_location('11748 S. Atenis Dr. South Jordan, UT')
  end

end
