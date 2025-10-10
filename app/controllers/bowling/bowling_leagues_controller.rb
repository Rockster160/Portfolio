module Bowling
  class BowlingLeaguesController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :authorize_user_or_guest, :set_league

    def index
      @leagues = current_user.bowling_leagues.order(updated_at: :asc)
    end

    def export
      BowlingExporter.export(@league)
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

    def destroy
      if @league.destroy
        redirect_to bowling_games_path
      else
        render :form
      end
    end

    def tms
      @stats = BowlingStatsCalculator.call(@league)
    end

    private

    def set_league
      if params[:id].present?
        @league = current_user.bowling_leagues.find(params[:id])
      else
        @league = BowlingLeague.new
      end
    end

    def league_params
      params.require(:bowling_league).permit(
        :name,
        :team_name,
        :lanetalk_center_uuid,
        :hdcp_base,
        :hdcp_factor,
        :absent_calculation,
        :games_per_series,
        :team_size,
        bowlers_attributes: [
          :_destroy,
          :id,
          :name,
          :position,
          :usbc_number,
          :usbc_full_name,
          :total_games_offset,
          :total_pins_offset,
        ],
      )
    end
  end
end
