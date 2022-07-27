module Bowling
  class BowlingGamesController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authorize_user
    before_action :set_ivars, except: [:index]

    def index
      @leagues = current_user.bowling_leagues.order(updated_at: :desc)
    end

    def new
      render :form
    end

    def edit
      render :form
    end

    private

    def user_sets
      BowlingSet.joins(:league).where(bowling_leagues: { user_id: current_user.id })
    end

    def set_ivars
      if params[:id].present?
        @set = user_sets.find(params[:id])
      elsif params[:series].present?
        @set = user_sets.find(params[:series])
      elsif params[:league]
        @set = user_sets.new(league_id: params[:league])
      else
        @set = user_sets.new
      end
      @league = @set.league || BowlingLeague.create_default(current_user)

      if params[:game].present?
        @games = @set.games_for_display(params[:game])
      else
        @games = @set.games_for_display
      end
    end
  end
end
