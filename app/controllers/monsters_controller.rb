class MonstersController < ApplicationController
  def show
    @monster = Monster.find(params[:id])
    render json: @monster, include: :monster_skills
  end
end
