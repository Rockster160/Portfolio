module Bowling
  class BowlingSetsController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authorize_user, :set_set

    def create
      @set.league_id ||= find_or_create_league_id

      if @set.update(bowling_params)
        if @set.complete?
          @set.save_scores # Don't save until the set is complete since handicap changes after the series
          redirect_to bowling_set_path(@set)
        else
          redirect_to new_bowling_game_path(series: @set, game: @set.games_complete + 1)
        end
      else
        puts "\e[33m[LOGIT] | Error creating: \n#{@set.errors.full_messages}\e[0m"
      end
    end

    def update
      @set.league_id ||= find_or_create_league_id

      if @set.update(bowling_params)
        if @set.complete?
          @set.save_scores # Don't save until the set is complete since handicap changes after the series
          redirect_to bowling_set_path(@set)
        else
          redirect_to new_bowling_game_path(series: @set, game: @set.games_complete + 1)
        end
      else
        puts "\e[33m[LOGIT] | Error creating: \n#{@set.errors.full_messages}\e[0m"
      end
    end

    private

    def set_set
      if params[:id].present?
        @set = BowlingSet.find(params[:id])
      else
        @set = BowlingSet.new(league_id: params[:league])
      end
    end

    def bowling_params
      params.require(:bowling_set).permit(
        # :league_id, - Done before saving
        games_attributes: [
          :id,
          :set_id,
          :bowler_id,
          :game_num,
          :handicap,
          :position,
          :card_point,
          :score,
          frames: 10.times.map { |idx| { idx.to_s.to_sym => [] } },
        ]
      )
    end

    def find_or_create_league_id
      params.dig(:bowling_set, :league_id).presence || BowlingLeague.create_default(current_user).id
    end
  end
end
