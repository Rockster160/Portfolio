# maze = Maze.new(20, 20)
# maze.draw
class Maze
  DIRECTIONS = [ [1, 0], [-1, 0], [0, 1], [0, -1] ]
  attr_accessor :start_str, :end_str, :path, :wall, :width, :height, :seed

  def initialize(width, height, options={})
    @seed = (options[:seed] || rand(999999)).to_i

    @start_str = options[:start_str].present? ? options[:start_str][0] : 'o'
    @end_str = options[:end_str].present? ? options[:end_str][0] : 'x'
    @path = options[:path].present? ? options[:path][0] : ' '
    @wall = options[:wall].present? ? options[:wall][0] : '#'

    @width   = width
    @height  = height
    @visited = Array.new(@width) { Array.new(@height) }

    @start_x = rand(width)
    @start_y = rand(height)
    @dead_ends = [{x: @start_x, y: @start_y}]

    @vertical_walls   = Array.new(width) { Array.new(height) {true} }
    @horizontal_walls = Array.new(width) { Array.new(height) {true} }

    generate_visit_cell(@start_x, @start_y)
  end

  def draw
    to_array.map { |row| row.join('') }
  end

  def to_array
    array = []
    array << @width.times.inject("#{@wall} ") {|str, x| str << "#{@wall} #{@wall} "}.scan(/../)
    srand(@seed)
    end_x, end_y = @dead_ends.sample.to_a.map(&:last)

    @height.times do |y|
      line = @width.times.inject("#{@wall} ") do |str, x|
        if @start_x == x && @start_y == y
          str << (@vertical_walls[x][y] ? "#{@start_str} #{@wall} " : "#{@start_str}   ")
        else
          str << (@vertical_walls[x][y] ? "  #{@wall} " : '    ')
        end
      end
      array << line.scan(/../)

      array << @width.times.inject("#{@wall} ") {|str, x| str << (@horizontal_walls[x][y] ? "#{@wall} #{@wall} " : "  #{@wall} ")}.scan(/../)
    end
    @dead_ends = find_dead_ends(array)
    downstairs_x, downstairs_y = @dead_ends.sample.to_a.map(&:last)
    array[downstairs_y][downstairs_x] = "#{@end_str} "
    array
  end

  private

  def find_dead_ends(grid)
    dead_ends = []
    grid.each_with_index do |row, y|
      row.each_with_index do |cell, x|
        next unless cell == '  '
        count_of_sides = 0
        sides = DIRECTIONS.map do |rel_x, rel_y|
          new_x, new_y = rel_x + x, rel_y + y
          count_of_sides += 1 if grid[new_y][new_x] == "#{@wall} "
          grid[new_y][new_x]
        end
        dead_ends << {x: x, y: y} if count_of_sides == 3
      end
    end
    dead_ends
  end

  def generate_visit_cell(x, y)
    @visited[x][y] = true

    coordinates = DIRECTIONS.shuffle.map { |dx, dy| [x + dx, y + dy] }

    coordinates.each do |new_x, new_y|
      @dead_ends << {x: new_x, y: new_y}
      next unless move_valid?(new_x, new_y)

      connect_cells(x, y, new_x, new_y)
      generate_visit_cell(new_x, new_y)
    end
  end

  def move_valid?(x, y)
    (0...@width).cover?(x) && (0...@height).cover?(y) && !@visited[x][y]
  end

  def connect_cells(x1, y1, x2, y2)
    if x1 == x2
      # Cells must be above each other, remove a horizontal wall.
      @horizontal_walls[x1][ [y1, y2].min ] = false
    else
      # Cells must be next to each other, remove a vertical wall.
      @vertical_walls[ [x1, x2].min ][y1] = false
    end
  end
end
