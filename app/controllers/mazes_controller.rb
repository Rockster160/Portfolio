class MazesController < ApplicationController

  def index
    redirect_to random_mazes_path(params.permit(:seed, :width, :height))
  end

  def random
    seed = (params[:seed] || rand(999999)).to_i
    srand(seed)

    width = params[:width].to_i > 0 ? params[:width].to_i : (rand(20) + 10)
    height = params[:height].to_i > 0 ? params[:height].to_i : (rand(20) + 10)
    width = width < 3 ? 3 : width
    height = height < 3 ? 3 : height
    width = width > 30 ? 30 : width
    height = height > 30 ? 30 : height

    options = {
      seed: seed,
      start_str: params[:start_str],
      end_str: params[:end_str],
      path: params[:path],
      wall: params[:wall]
    }

    @maze = Maze.new(width, height, options)

    respond_to do |format|
      format.text { render plain: @maze.draw.join("\n") }
      format.html
    end
  end

end
