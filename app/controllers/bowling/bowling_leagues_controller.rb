module Bowling
  class BowlingLeaguesController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authorize_user, :set_league

    def index
      @leagues = current_user.bowling_leagues.order(updated_at: :desc)
    end

    def new
      render :form
    end

    def edit
      render :form
    end

    def create
      @league = BowlingLeague.create(league_params.merge(user: current_user))

      if @league.persisted?
        redirect_to @league
      else
        render :form
      end
    end

    def update
      if @league.update(league_params)
        redirect_to @league
      else
        render :form
      end
    end

    private

    def set_league
      if params[:id].present?
        @league = BowlingLeague.find(params[:id])
      else
        @league = BowlingLeague.new
      end
    end

    def league_params
      params.require(:bowling_league).permit(
        :name,
        :team_name,
        :handicap_calculation,
        :absent_calculation,
        :games_per_series,
        :team_size,
        bowlers_attributes: [
          :_destroy,
          :id,
          :name,
          :position,
          :total_games_offset,
          :total_pins_offset,
        ]
      )
    end

  end
end
