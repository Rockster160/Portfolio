module Bowling
  class BowlingGamesController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authorize_user
    before_action :set_ivars, except: [:index]
    helper_method :extract_lane_number

    def index
      @leagues = current_user.bowling_leagues.order(updated_at: :desc)
    end

    def new
      if params[:series].blank?
        redirect_to new_bowling_game_path(league: @set.league_id, series: @set.id, game: 1)
      else
        render :form
      end
    end

    def edit
      render :form
    end

    private

    def extract_lane_number
      current_user.jarvis_cache.get(:next_bowling_lane)&.tap {
        current_user.jarvis_cache.set(:next_bowling_lane, nil)
      }
    end

    def user_sets
      BowlingSet.joins(:league).where(bowling_leagues: { user_id: current_user.id })
    end

    def set_ivars
      if params[:id].present?
        @set = user_sets.find(params[:id])
      elsif params[:series].present?
        @set = user_sets.find(params[:series])
      elsif params[:league]
        @set = user_sets.create(league_id: params[:league])
      else
        @set = user_sets.create
      end
      @league = @set.league || BowlingLeague.create_default(current_user)
      @set.league ||= @league

      if params[:game].present?
        @games = @set.games_for_display(params[:game])
      else
        @games = @set.games_for_display
      end
    end
  end
end
