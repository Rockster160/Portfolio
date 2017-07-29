class MapGenerator
  attr_accessor :width, :height

  def self.generate
    new
  end

  def initialize
    grass_layer = File.read("lib/assets/little_world/map_layers/grass.map")
    collision_layer = File.read("lib/assets/little_world/map_layers/collision.map")
    @grass_cells = grass_layer.split("\n").map { |row| row.split("") }
    @collision_cells = collision_layer.split("\n").map { |row| row.split("") }
    @width = @grass_cells.map(&:length).max + 1
    @height = @grass_cells.length + 1
  end

  def to_html
    world_html = ""

    @height.times do |y|
      @width.times do |x|
        grass_cell = cell_at_coord(@grass_cells, x, y)
        collision_cell = cell_at_coord(@collision_cells, x, y)

        klass_list = ["block", grass_class_by_char(grass_cell)]
        if collision_cell == "0"
          klass_list << "walkable grass-2" # FIXME
          inner_block = ""
        else
          inner_block = div(["object", object_class_by_char(collision_cell)])
        end

        world_html << div(klass_list, inner_block, {"data-x" => x, "data-y" => y})
      end
      world_html << "<br>"
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

  def object_class_by_char(char)
    case char
    when "1" then "cactus"
    end
  end

  def cell_at_coord(cells, x, y)
    cells.dig(y, x)
  end

  def div(klasses, body=nil, attribute_hash={})
    klass_list = [klasses].flatten.compact.join(" ")
    attributes = attribute_hash.map do |attribute_key, attribute_val|
      next if attribute_key.blank?
      next attribute_key if attribute_val.blank?
      "#{attribute_key}=\"#{attribute_val}\""
    end
    attribute_list = " #{attributes.compact.join(' ')}"
    "<div class=\"#{klass_list}\"#{attribute_list.presence}>#{body}</div>"
  end

end
