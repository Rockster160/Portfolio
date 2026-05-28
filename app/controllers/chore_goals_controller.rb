class ChoreGoalsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_goal, only: [:update, :destroy]

  def create
    goal = current_user.chore_goals.create!(goal_params)
    render json: serialize(goal), status: :created
  end

  def update
    @goal.update!(goal_params)
    render json: serialize(@goal)
  end

  def destroy
    @goal.update!(archived_at: Time.current)
    head :no_content
  end

  private

  def set_goal
    @goal = current_user.chore_goals.find(params[:id])
  end

  def goal_params
    params.require(:chore_goal).permit(:name, :image_url, :link_url, :cost_pebbles)
  end

  def serialize(goal)
    {
      id: goal.id,
      name: goal.name,
      image_url: goal.image_url,
      link_url: goal.link_url,
      cost_pebbles: goal.cost_pebbles,
      achieved_at: goal.achieved_at,
    }
  end
end
