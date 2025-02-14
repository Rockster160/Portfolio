class MazesController < ApplicationController
  skip_before_action :verify_authenticity_token

  def show
    @seed = (params[:seed] || rand(999999)).to_i
    headers["X-Maze-Seed"] = @seed

    generate_maze

    respond_to do |format|
      format.text { render plain: @maze.draw.join("\n") }
      format.html
    end
  end

  def solve
    @seed = params[:seed].to_i
    headers["X-Maze-Seed"] = @seed


    runner = MazeRunner.new(generate_maze)
    runner.move(params[:moves])

    if runner.complete?
      render plain: runner.draw.join("\n"), status: :ok
    else
      render plain: runner.draw.join("\n"), status: :partial_content
    end
  rescue MazeRunner::MazeRunnerError => e
    render plain: runner.draw.join("\n"), status: :unprocessable_entity
  end

  def redirect
    redirect_to maze_path(params.except(:action, :controller).permit!.compact_blank)
  end

  private

  def generate_maze
    srand(@seed)

    width = params[:width].to_i > 0 ? params[:width].to_i : (rand(20) + 10)
    height = params[:height].to_i > 0 ? params[:height].to_i : (rand(20) + 10)
    width = [3, width, 50].sort[1]
    height = [3, height, 50].sort[1]

    options = {
      seed: @seed,
      start_str: params[:start_str]&.first,
      end_str: params[:end_str]&.first,
      path: params[:path]&.first,
      wall: params[:wall]&.first
    }

    @maze = Maze.new(width, height, options)
  end
end
