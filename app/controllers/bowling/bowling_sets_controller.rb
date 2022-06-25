module Bowling
  class BowlingSetsController < ApplicationController
    # skip_before_action :verify_authenticity_token
    before_action :authorize_user, :set_set

    def show
      @league = @set.league
      @stats = BowlingStatsCalculator.call(@league, @set)
    end

    def create
      @league = find_or_create_league
      @set.league_id ||= @league.id

      if @set.update(bowling_params)
        if @set.complete?
          @set.save_scores # Don't save until the set is complete since handicap changes after the series
          render status: :created, json: { redirect: bowling_set_path(@set) }
        else
          render status: :created, json: { redirect: new_bowling_game_path(series: @set, game: @set.games_complete + 1) }
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
          @set.future_save # Special method to update future stats in case an old game changed
          render status: :created, json: { redirect: bowling_set_path(@set) }
        else
          render status: :created, json: { redirect: new_bowling_game_path(series: @set, game: @set.games_complete + 1) }
        end
      else
        puts "\e[33m[LOGIT] | Error creating: \n#{@set.errors.full_messages}\e[0m"
      end
    end

    def destroy
      if @set.destroy
        @set.league.bowlers.each(&:recalculate_scores)

        redirect_to bowling_league_path(@set.league)
      else
        redirect_to bowling_set_path(@set), alert: "Failed to destroy set: #{@set.errors.full_messages.join("\n")}"
      end
    end

    private

    def user_sets
      BowlingSet.joins(:league).where(bowling_leagues: { user_id: current_user.id })
    end

    def set_set
      if params[:id].present?
        @set = user_sets.find(params[:id])
      else
        @set = user_sets.new(league_id: params[:league])
      end
    end

    def bowling_params
      params.require(:bowling_set).permit(
        # :league_id, - Done before saving
        games_attributes: [
          :id,
          :set_id,
          :absent,
          :bowler_id,
          :bowler_name,
          :game_num,
          :handicap,
          :position,
          :card_point,
          :score,
          frames: 10.times.map { |idx| { idx.to_s.to_sym => [] } },
          frames_details: [
            :frame_num,
            :throw1,
            :throw2,
            :throw3,
            :throw1_remaining,
            :throw2_remaining,
            :throw3_remaining,
            :strike_point,
          ]
        ]
      ).tap do |whitelist|
        whitelist[:games_attributes] = whitelist[:games_attributes].map do |game_attributes|
          game_attributes.tap do |game_whitelist|
            game_whitelist[:bowler_id] = game_whitelist[:bowler_id].presence || @league.bowlers.create(name: game_whitelist[:bowler_name]).id
          end
        end
      end
    end

    def find_or_create_league
      @league ||= begin
        league_id = params.dig(:bowling_set, :league_id)
        return current_user.bowling_leagues.find(league_id) if league_id.present?

        BowlingLeague.create_default(current_user)
      end
    end
  end
end
