module Bowling
  class BowlingSetsController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authorize_user, :set_set

    def create
      @league = find_or_create_league
      @set.league_id ||= @league.id

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
      @league = find_or_create_league
      @set.league_id ||= @league.id

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
          :bowler_name,
          :game_num,
          :handicap,
          :position,
          :card_point,
          :score,
          frames: 10.times.map { |idx| { idx.to_s.to_sym => [] } },
        ]
      ).tap do |whitelist|
        whitelist[:games_attributes] = whitelist[:games_attributes].map do |game_attributes|
          game_attributes.tap do |game_whitelist|
            game_attributes[:bowler_id] = game_attributes[:bowler_id].presence || @league.bowlers.create(name: game_attributes[:bowler_name]).id
          end
        end
      end
    end

    def find_or_create_league
      @league ||= begin
        league_id = params.dig(:bowling_set, :league_id)
        return BowlingLeague.find(league_id) if league_id.present?

        BowlingLeague.create_default(current_user)
      end
    end
  end
end
