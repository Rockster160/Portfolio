module Bowling
  class BowlersController < ApplicationController
    # skip_before_action :verify_authenticity_token
    before_action :set_league, only: [:create]
    # before_action :authorize_user, :set_league

    def create
      @bowler = @league.bowlers.create(bowler_params.merge(position: @league.bowlers.count + 1))
      if @bowler.persisted?
        @bowler.recalculate_scores
        template = BowlersController.render partial: "bowling/bowling_games/bowling_game_form", locals: {
          bowler: @bowler,
          game: BowlingGame.new(game_num: params.dig(:bowler, :game_num), bowler: @bowler),
        }

        respond_to do |format|
          format.json { render json: { html: template } }
        end
      else
        puts "\e[33m[LOGIT] | Error creating: \n#{@bowler.errors.full_messages}\e[0m"
      end
    end

    def throw_stats
      @league = current_user.bowling_leagues.find_by(id: params[:league_id])
      @bowler = @league&.bowlers&.find_by(id: params[:bowler_id])

      return render json: { status: :ok, stats: {} } if @bowler.nil?

      stats = BowlingStats.pickup(@bowler, params[:pins])

      render json: { status: :ok, stats: { spare: stats[0], total: stats[1] } }
    end

    private

    def bowler_params
      params.require(:bowler).permit(
        # :league_id, - Done before saving
        :name,
        :total_games_offset,
        :total_pins_offset,
      )
    end

    def set_league
      @league ||= begin
        league_id = params.dig(:bowler, :league_id)

        # BowlingLeague.find(league_id)
        current_user.bowling_leagues.find(league_id)
      end
    end
  end
end
