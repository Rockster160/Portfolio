module Bowling
  class BowlingGamesController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authorize_user, :set_ivars

    def index
      @leagues = current_user.bowling_leagues
    end

    def new
      render :form
    end

    def edit
      render :form
    end

    private

    def set_ivars
      if params[:id].present?
        @game = BowlingGame.find(params[:id])
        @set = @game.set
      elsif params[:series].present?
        @set = BowlingSet.find(params[:series])
      elsif params[:league]
        @set = BowlingSet.new(league_id: params[:league])
      else
        @set = BowlingSet.new
      end

      return if @game.present?

      if params[:game].present?
        @games = @set.games_for_display(params[:game])
      else
        @games = @set.games_for_display
      end
    end
  end
end
