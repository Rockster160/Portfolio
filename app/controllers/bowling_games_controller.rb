class BowlingGamesController < ApplicationController

  def show
    if params[:game].present?
      @game = BowlingGame.find(params[:game])
    else
      @game = BowlingGame.new
    end
  end

  def update
  end

end
