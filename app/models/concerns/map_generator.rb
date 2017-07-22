class MapGenerator

  def self.generate
    new.to_html
  end

  def initialize
    world_str = File.read("lib/assets/little_world_map.map")
    grass_layer, spikes_layer, collision_layer = world_str.split("\n")
    grass_rows, spikes_rows, collision_rows = [grass_layer, spikes_layer, collision_layer].map { |layer| layer.split(",") }
    @grass_cells, @spikes_cells, @collision_cells = [grass_rows, spikes_rows, collision_rows].map { |layer_rows| layer_rows.map { |row| row.split("") } }
  end

  def to_html
    world_html = ""

    @grass_cells.each_with_index do |grass_row, y|
      grass_row.each_with_index do |grass_cell, x|
        puts "#{grass_cell}".colorize(:red)
        klass_list = ["block", grass_class_by_char(grass_cell)]
        klass_list << "walkable" unless cell_at_coord(@collision_cells, x, y) == "1"
        inner_block = div("object stop-walk") if cell_at_coord(@spikes_cells, x, y) == "1"

        world_html << div(klass_list, inner_block)
      end
    end

    div("game", world_html).html_safe
  end

  def grass_class_by_char(char)
    case char
    when "N" then "top-left-grass"
    when "W" then "bottom-left-grass"
    when "E" then "top-right-grass"
    when "S" then "bottom-right-grass"
    when "w" then "left-grass"
    when "n" then "top-grass"
    when "e" then "right-grass"
    when "s" then "bottom-grass"
    when "1" then "grass-1"
    when "2" then "grass-2"
    when "3" then "grass-3"
    when "4" then "grass-4"
    end
  end

  def cell_at_coord(cells, x, y)
    cells.dig(y, x)
  end

  def div(klasses, body=nil)
    klass_list = [klasses].flatten.join(" ")
    "<div class=\"#{klass_list}\">#{body}</div>"
  end

end
