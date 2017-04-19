class MazesController < ApplicationController

  def index
    redirect_to random_mazes_path
  end

  def random
    seed = (params[:seed] || rand(999999)).to_i
    srand(seed)
    width = params[:width] || (rand(20) + 10)
    height = params[:height] || (rand(20) + 10)
    options = {
      seed: params[:seed],
      start_str: params[:start_str],
      end_str: params[:end_str],
      path: params[:path],
      wall: params[:wall]
    }

    @maze = Maze.new(width, height, options)

    respond_to do |format|
      format.text { render text: @maze.draw.join('\n') }
      format.html
    end
  end

end
