class MazesController < ApplicationController
  skip_before_action :verify_authenticity_token

  def show
    @seed = (params[:seed] || rand(999999)).to_i
    srand(@seed)

    width = params[:width].to_i > 0 ? params[:width].to_i : (rand(20) + 10)
    height = params[:height].to_i > 0 ? params[:height].to_i : (rand(20) + 10)
    width = [3, width, 30].sort[1]
    height = [3, height, 30].sort[1]

    options = {
      seed: @seed,
      start_str: params[:start_str]&.first,
      end_str: params[:end_str]&.first,
      path: params[:path]&.first,
      wall: params[:wall]&.first
    }

    @maze = Maze.new(width, height, options)

    respond_to do |format|
      format.text { render plain: @maze.draw.join("\n") }
      format.html
    end
  end

  def redirect
    redirect_to maze_path(params.except(:action, :controller).permit!.compact_blank)
  end
end
