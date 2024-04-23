module Bowling
  class BowlingSetsController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authorize_user_or_guest, :set_set

    def show
      @league = @set.league
      @stats = BowlingStatsCalculator.call(@league, @set)
    end

    def create
      @league = find_or_create_league
      @set.league_id ||= @league.id

      if @set.update(bowling_params)
        @set.games.each(&:save) # Hack because double gutter isn't registering as a change to games
        if params[:throw_update].present?
          render status: :created, json: game_data
        elsif @set.complete?
          @set.save_scores # Don't save until the set is complete since handicap changes after the series
          render status: :created, json: game_data.merge({ redirect: bowling_set_path(@set) })
        else
          render status: :created, json: game_data.merge({ redirect: new_bowling_game_path(series: @set, game: @set.games_complete + 1) })
        end
      else
        # puts "\e[33m[LOGIT] | Error creating: \n#{@set.errors.full_messages}\e[0m"
      end
    end

    def update
      @league = find_or_create_league
      @set.league_id ||= @league.id

      if @set.update(bowling_params)
        started_frame_9 = params.dig(:bowling_set, :games_attributes).values&.any? { |game|
          next false unless game[:game_num] == "3"
          game.dig(:frames_details, "8", :throw1).present? # 8 is index, so frame 9
        }
        if started_frame_9 && current_user.admin?
          if !User.me.jarvis_caches.get(:bowlingCarStarted)
            User.me.jarvis_caches.set(:bowlingCarStarted, true)
            Jarvis.say("Starting car for 9th frame")
            Jarvis.command(current_user, "Take me home") if Rails.env.production?
          end
        end
        if params[:throw_update].present?
          render status: :created, json: game_data
        elsif @set.complete?
          @set.future_save # Special method to update future stats in case an old game changed
          render status: :created, json: game_data.merge({ redirect: bowling_set_path(@set) })
        else
          render status: :created, json: game_data.merge({ redirect: new_bowling_game_path(series: @set, game: @set.games_complete + 1) })
        end
      else
        # puts "\e[33m[LOGIT] | Error creating: \n#{@set.errors.full_messages}\e[0m"
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

    def remove_bowler
      game = @set.games.find_by!(bowler_id: params[:bowler_id], game_num: game_num)
      if game.destroy
        # NOTE: This doesn't currently reset the bowler's scores.
        # If a bowler is removed from an old game, it will mess up future averages
        render status: :accepted, json: {}
      else
        render status: :bad_request, json: {}
      end
    end

    private

    def game_num
      return params[:game].to_i if params[:game].present?
      return params[:game_num].to_i if params[:game_num].present?
      game = params.dig(:bowling_set, :games_attributes)&.values&.first || {}

      (game[:game_num].presence || 1).to_i
    end

    def game_data
      {
        league_id: @league.id,
        set_id: @set.id,
        game_num: game_num,
        bowlers: @set.games_for_display(game_num).joins(:bowler).map { |game|
          { id: game.bowler.id, name: game.bowler.name, bowler_game_id: game.id }
        }
      }
    end

    def user_sets
      BowlingSet.joins(:league).where(bowling_leagues: { user_id: current_user.id })
    end

    def set_set
      if params[:id].present? || params[:set_id].present?
        @set = user_sets.find(params[:id] || params[:set_id])
      else
        @set = user_sets.new(league_id: params[:league])
      end
    end

    def bowling_params
      params.require(:bowling_set).permit(
        # :league_id, - Done before saving
        :lane_number,
      ).merge({
        games_attributes: (
          params.dig(:bowling_set, :games_attributes).values.map { |g| g.permit(
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
          )}
        )
      })
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
