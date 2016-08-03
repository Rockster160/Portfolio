class MazesController < ApplicationController

  def random
    width = params[:width] || (rand(20) + 10)
    height = params[:height] || (rand(20) + 10)
    options = {
      seed: params[:seed],
      start_str: params[:start_str],
      end_str: params[:end_str],
      path: params[:path],
      wall: params[:wall]
    }
    @maze = Maze.new(30, 30, options)
    render text: @maze.draw.join('\n')
  end

end
