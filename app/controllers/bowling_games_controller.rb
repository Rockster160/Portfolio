class BowlingGamesController < ApplicationController

  def show
    if params[:game].present?
      @game = BowlingGame.find(params[:game])
    else
      @game = BowlingGame.new
    end
  end

  def create
    @game = BowlingGame.create(bowling_params)
  end

  def update
    # if params[:id].present?
    #   @game = BowlingGame.find(params[:game])
    # else
    #   @game = BowlingGame.new
    # end
    # @game = BowlingGame.create(bowling_params)
  end

  private

  def bowling_params
    params.require(:bowling_game).permit(
      :game_data
    )
  end

end
