class MazeRunner
  class MazeRunnerError < StandardError;end
  def initialize(maze)
    @x = (maze.start_x * 2) + 1
    @y = (maze.start_y * 2) + 1
    @wall = maze.wall
    @finish = maze.end_str
    @maze = maze.draw
  end

  def complete?
    at(@x, @y) == @finish
  end

  def crash?
    at(@x, @y) == @wall
  end

  def at(x, y)
    @maze[y][x*2]
  end

  def move(str)
    dirs = {
      U: [0, -1],
      R: [1, 0],
      D: [0, 1],
      L: [-1, 0],
    }
    str.split("").each do |dir|
      rx, ry = dirs[dir.upcase.to_sym]
      @x += rx
      @y += ry
      raise MazeRunnerError, "Invalid move" if crash?
    end

    return "You win!" if complete?
  end

  def draw
    @maze.map.with_index { |row, cy|
      row.scan(/../).map.with_index { |cell, cx|
        next "• " if cy == @y && cx == @x
        # next "\e[45;36m• \e[0m" if cy == @y && cx == @x
        cell
      }.join("")
    }
  end
end
