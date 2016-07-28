require 'csv'
class Pokedex

  def self.pokelist
    list = []
    CSV.foreach('pokedex.csv') do |row|
      list << row
    end
    list
  end

  def self.id_and_name_by_id_or_name(id_or_name)
    is_id = id_or_name.is_a?(Integer) || id_or_name.to_i.to_s == id_or_name
    is_id ? pokelist[id_or_name.to_i - 1] : row_by_name(id_or_name)
  end

  def self.name_by_id(id)
    pokelist[id.to_i - 1].try(:last)
  end

  def self.row_by_name(name)
    pokelist.select { |pl| pl[1].downcase == name.downcase }.first
  end

end
