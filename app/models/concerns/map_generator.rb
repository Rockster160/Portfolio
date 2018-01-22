class MapGenerator
  attr_accessor :width, :height

  def self.render_chunk_from_position(x, y)
    Chunk.from_position(x, y).to_html.html_safe
  end

  def self.render_chunk_by_coord(x, y)
    Chunk.new(x, y).to_html.html_safe
  end

  # def to_html
  #   world_html = ""
  #   @height.times do |y|
  #     @width.times do |x|
  #       collision_cell = "0"
  #
  #       klass_list = ["block", generate_grass_for_cell(x, y)]
  #       if collision_cell == "0"
  #         klass_list << "walkable"
  #         inner_block = ""
  #       else
  #         inner_block = div(["object", object_class_by_char(collision_cell)])
  #       end
  #
  #       world_html << div(klass_list, inner_block, {"data-x" => x, "data-y" => y})
  #     end
  #     world_html << "<br>"
  #   end
  #
  #   div("game", world_html).html_safe
  # end
  #
  # def set_relative_grass_cells(x, y)
  #   up_left_grass = cell_is_grass?(x - 1, y - 1)
  #   up_mid_grass = cell_is_grass?(x, y - 1)
  #   up_right_grass = cell_is_grass?(x + 1, y - 1)
  #
  #   mid_left_grass = cell_is_grass?(x - 1, y)
  #   mid_mid_grass = cell_is_grass?(x, y)
  #   mid_right_grass = cell_is_grass?(x + 1, y)
  #
  #   down_left_grass = cell_is_grass?(x - 1, y + 1)
  #   down_mid_grass = cell_is_grass?(x, y + 1)
  #   down_right_grass = cell_is_grass?(x + 1, y + 1)
  #
  #   @relative_grass_cells = {
  #     up_left: up_left_grass,     up: up_mid_grass,     up_right: up_right_grass,
  #     left: mid_left_grass,       mid: mid_mid_grass,   right: mid_right_grass,
  #     down_left: down_left_grass, down: down_mid_grass, down_right: down_right_grass
  #   }
  # end
  #
  # def check_relative_grass(all_present, not_allowed)
  #   return false if all_present.none?
  #   all = [:up_left, :up, :up_right, :left, :mid, :right, :down_left, :down, :down_right]
  #   not_allowed = not_allowed + (all - all_present) if not_allowed.include?(:all)
  #   expected_present = all_present.all? { |direction_sym| @relative_grass_cells[direction_sym] }
  #   expected_empty = not_allowed.none? { |direction_sym| @relative_grass_cells[direction_sym] }
  #   expected_present && expected_empty
  # end
  #
  # def generate_grass_for_cell(x, y)
  #   set_relative_grass_cells(x, y)
  #
  #   case
  #   when check_relative_grass([:down, :left, :down_left], [:mid]) then "grass-down-left-inner-corner"
  #   when check_relative_grass([:down, :right, :down_right], [:mid]) then "grass-down-right-inner-corner"
  #   when check_relative_grass([:up, :left, :up_left], [:mid]) then "grass-up-left-inner-corner"
  #   when check_relative_grass([:up, :right, :up_right], [:mid]) then "grass-up-right-inner-corner"
  #
  #   when check_relative_grass([:down_left], [:mid, :down, :left]) then "grass-down-left-corner"
  #   when check_relative_grass([:down_right], [:mid, :down, :right]) then "grass-down-right-corner"
  #   when check_relative_grass([:up_left], [:mid, :up, :left]) then "grass-up-left-corner"
  #   when check_relative_grass([:up_right], [:mid, :up, :right]) then "grass-up-right-corner"
  #
  #   when check_relative_grass([:right], [:mid, :left]) then "grass-left-edge"
  #   when check_relative_grass([:left], [:mid, :right]) then "grass-right-edge"
  #   when check_relative_grass([:up], [:mid, :down]) then "grass-down-edge"
  #   when check_relative_grass([:down], [:mid, :up]) then "grass-up-edge"
  #
  #   when check_relative_grass([:mid], []) then rand_grass(x, y)
  #   else
  #     "space"
  #   end
  # end
  #
  # def rand_grass(x, y)
  #   rand_block = @cells.dig(y, x)
  #   return "check" if rand_block <= 15
  #   return "grass" if rand_block <= 20
  #   return "grass-2" if rand_block <= 25
  #   return "grass-3" if rand_block <= 30
  #   return "grass-4" if rand_block <= 35
  #   "bad"
  # end
  #
  # def cell_is_grass?(x, y)
  #   return false if x < 0 || x >= @width
  #   return false if y < 0 || y >= @height
  #   cell_at_coord(x, y).present?
  # end
  #
  # def object_class_by_char(char)
  #   case char
  #   when "x" then "cactus"
  #   end
  # end
  #
  # def cell_at_coord(x, y)
  #   @cells.dig(y, x)
  # end
  #
  def self.div(klasses, body=nil, attribute_hash={})
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

class Chunk
  CHUNK_SIZE = 16
  attr_accessor :width, :height,
    :x, :y,
    :ne_x, :ne_y,
    :cells, :cell_data

  def self.from_position(x, y)
    new(x.round / CHUNK_SIZE, y.round / CHUNK_SIZE)
  end

  def initialize(chunk_x, chunk_y)
    @x, @y = chunk_x, chunk_y
    @width, @height = CHUNK_SIZE, CHUNK_SIZE
    @ne_x, @ne_y = chunk_x * CHUNK_SIZE, chunk_y * CHUNK_SIZE

    puts "Building chunk for (#{@x}, #{@y})".colorize(:red)
    generate_cell_data
    generate_cells
  end

  def generate_cell_data
    # noise = ::Perlin::Noise.new(2, seed: 3141)
    noise = ::Perlin::Generator.new(3141, 1.0, 1)
    # These numbers range from 0..1 with about 16 decimal points
    # The numbers tend to stay close to, but above 0.5
    noise_step_scale = 0.02 # This controls the "size" of the areas
    sensible_multiplier = 50 # This gives us a range from 0..100 instead of -1..1

    @cell_data = @height.times.map do |cell_y|
      @width.times.map do |cell_x|
        noise_x = noise_step_scale * (@ne_x + cell_x)
        noise_y = noise_step_scale * (@ne_y + cell_y)
        (noise[noise_x, noise_y] * sensible_multiplier) + sensible_multiplier
      end
    end
  end

  def generate_cells
    @cells = @cell_data.map.with_index do |col, cell_y|
      col.map.with_index do |cell_data, cell_x|
        Cell.new(cell_data, cell_x, cell_y, @x, @y)
      end
    end
  end

  def cell_html
    @cells.map do |row|
      row.map(&:to_html).join("")
    end.join("")
  end

  def to_s
    @cells.map do |row|
      row.map(&:to_s).join("")
    end.join("\n")
  end

  def to_html
    @html ||= begin
      MapGenerator.div("chunk", cell_html, {"data-chunk-x" => @x, "data-chunk-y" => @y})
    end
  end
end

class Cell
  attr_accessor :cell_data,
    :world_x, :world_y,
    :chunk_x, :chunk_y,
    :x, :y,
    :style_classes,
    :content

  def initialize(cell_data, x, y, chunk_x, chunk_y)
    @cell_data = cell_data
    @x         = x
    @y         = y
    @chunk_x   = chunk_x
    @chunk_y   = chunk_y
    @world_x   = @x + (@chunk_x * Chunk::CHUNK_SIZE)
    @world_y   = @y + (@chunk_y * Chunk::CHUNK_SIZE)

    set_style_classes
  end

  def walkable?
    @walkable ||= begin
      !(@cell_data <= 10 || @cell_data > 95)
    end
  end

  def set_style_classes
    @style_classes ||= begin
      klass_map = []
      klass_map << :block
      klass_map << :walkable if walkable?
      mod_cell = cell_type
      mod_num = @cell_data.to_s.split(".").last.first.to_i % 4
      mod_cell += "-#{mod_num}" if mod_num != 0 && mod_cell != "bad"
      klass_map << mod_cell

      klass_map.join(" ")
    end
  end

  def cell_type
    # generate_grass_for_cell(x, y)
    return "water"       if @cell_data <= 10
    return "sand"        if @cell_data <= 20
    return "grass"       if @cell_data <= 45
    return "grass-dark"  if @cell_data <= 65
    return "stone"       if @cell_data <= 85
    return "stone-med"   if @cell_data <= 90
    return "stone-dark"  if @cell_data <= 95
    return "stone-black" if @cell_data <= 96
    return "lava"        if @cell_data <= 100
    "bad"
  end

  def to_s
    cell_data_num = "#{@cell_data.round.to_s.rjust(4, ' ')}"
    case cell_type
    when "water"       then cell_data_num.colorize(color: :black, background: :blue)
    when "sand"        then cell_data_num.colorize(color: :black, background: :yellow)
    when "grass"       then cell_data_num.colorize(color: :black, background: :light_green)
    when "grass-dark"  then cell_data_num.colorize(color: :black, background: :green)
    when "stone"       then cell_data_num.colorize(color: :black, background: :light_red)
    when "stone-med"   then cell_data_num.colorize(color: :black, background: :light_magenta)
    when "stone-dark"  then cell_data_num.colorize(color: :black, background: :magenta)
    when "stone-black" then cell_data_num.colorize(color: :black, background: :magenta)
    when "lava"        then cell_data_num.colorize(color: :black, background: :red)
    else cell_data_num.colorize(color: :white, background: :black)
    end
  end

  def to_html
    MapGenerator.div(@style_classes, @content, {"data-x" => @world_x, "data-y" => @world_y, "data-rel-x" => @x, "data-rel-y" => @y, "data-chunk-x" => @chunk_x, "data-chunk-y" => @chunk_y})
  end
end
