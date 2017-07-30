class MapGenerator
  attr_accessor :width, :height

  def self.generate
    new
  end

  def initialize
    srand(3141)
    grass_layer = File.read("lib/assets/little_world/map_layers/grass.map")
    collision_layer = File.read("lib/assets/little_world/map_layers/collision.map")
    @grass_cells = grass_layer.split("\n").map { |row| row.split("") }
    @collision_cells = collision_layer.split("\n").map { |row| row.split("") }
    @width = @grass_cells.map(&:length).max + 2
    @height = @grass_cells.length + 2
  end

  def to_html
    world_html = ""
    @height.times do |high_y|
      @width.times do |high_x|
        x = high_x - 1
        y = high_y - 1
        grass_cell = cell_at_coord(@grass_cells, x, y)
        collision_cell = cell_at_coord(@collision_cells, x, y)

        klass_list = ["block", generate_grass_for_cell(x, y)]
        if collision_cell == "0"
          klass_list << "walkable"
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

  def set_relative_grass_cells(x, y)
    up_left_grass = cell_is_grass?(x - 1, y - 1)
    up_mid_grass = cell_is_grass?(x, y - 1)
    up_right_grass = cell_is_grass?(x + 1, y - 1)

    mid_left_grass = cell_is_grass?(x - 1, y)
    mid_mid_grass = cell_is_grass?(x, y)
    mid_right_grass = cell_is_grass?(x + 1, y)

    down_left_grass = cell_is_grass?(x - 1, y + 1)
    down_mid_grass = cell_is_grass?(x, y + 1)
    down_right_grass = cell_is_grass?(x + 1, y + 1)

    @relative_grass_cells = {
      up_left: up_left_grass,     up: up_mid_grass,     up_right: up_right_grass,
      left: mid_left_grass,       mid: mid_mid_grass,   right: mid_right_grass,
      down_left: down_left_grass, down: down_mid_grass, down_right: down_right_grass
    }
  end

  def check_relative_grass(all_present, not_allowed)
    return false if all_present.none?
    all = [:up_left, :up, :up_right, :left, :mid, :right, :down_left, :down, :down_right]
    not_allowed = not_allowed + (all - all_present) if not_allowed.include?(:all)
    expected_present = all_present.all? { |direction_sym| @relative_grass_cells[direction_sym] }
    expected_empty = not_allowed.none? { |direction_sym| @relative_grass_cells[direction_sym] }
    expected_present && expected_empty
  end

  def generate_grass_for_cell(x, y)
    set_relative_grass_cells(x, y)

    case
    when check_relative_grass([:down, :left, :down_left], [:mid]) then "grass-down-left-inner-corner"
    when check_relative_grass([:down, :right, :down_right], [:mid]) then "grass-down-right-inner-corner"
    when check_relative_grass([:up, :left, :up_left], [:mid]) then "grass-up-left-inner-corner"
    when check_relative_grass([:up, :right, :up_right], [:mid]) then "grass-up-right-inner-corner"

    when check_relative_grass([:down_left], [:mid, :down, :left]) then "grass-down-left-corner"
    when check_relative_grass([:down_right], [:mid, :down, :right]) then "grass-down-right-corner"
    when check_relative_grass([:up_left], [:mid, :up, :left]) then "grass-up-left-corner"
    when check_relative_grass([:up_right], [:mid, :up, :right]) then "grass-up-right-corner"

    when check_relative_grass([:right], [:mid, :left]) then "grass-left-edge"
    when check_relative_grass([:left], [:mid, :right]) then "grass-right-edge"
    when check_relative_grass([:up], [:mid, :down]) then "grass-down-edge"
    when check_relative_grass([:down], [:mid, :up]) then "grass-up-edge"

    when check_relative_grass([:mid], []) then rand_grass
    else
      "space"
    end
  end

  def rand_grass
    rand_block = rand(15)
    return "grass-length-1" if rand_block <= 5
    return "grass-length-2" if rand_block <= 9
    return "grass-length-3" if rand_block <= 12
    return "grass-length-4" if rand_block <= 14
    "bad"
  end

  def cell_is_grass?(x, y)
    return false if x < 0 || x >= @width
    return false if y < 0 || y >= @height
    cell_at_coord(@grass_cells, x, y).present?
  end

  def object_class_by_char(char)
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
