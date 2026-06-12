class ChoreGoalsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_goal, only: [:update, :destroy, :reopen]

  def create
    goal = current_user.chore_goals.create!(goal_params)
    # Catch the edge case where the user's current state already
    # satisfies the brand-new target.
    goal.refresh!
    render json: serialize(goal), status: :created
  end

  def update
    @goal.update!(goal_params)
    @goal.refresh!
    render json: serialize(@goal)
  end

  def destroy
    @goal.update!(archived_at: Time.current)
    head :no_content
  end

  # Manual override for the "lock" — clears achieved_at and re-checks.
  # If the goal's conditions are still genuinely met (e.g. balance still
  # over target) refresh! immediately re-locks it; otherwise it drops
  # back to outstanding with live-computed progress. Lets a user fix a
  # goal that locked from completions they've since undone.
  def reopen
    @goal.update!(achieved_at: nil)
    @goal.refresh!
    render json: serialize(@goal)
  end

  private

  def set_goal
    @goal = current_user.chore_goals.find(params[:id])
  end

  def goal_params
    permitted = params.require(:chore_goal).permit(
      :name, :description, :image_url, :link_url,
      :kind, :scope_mode, :tracking_mode,
      :target_value, :awarded_pebbles, :chore_id
    )
    # chore_id only applies to chore-specific kinds — a kind switch in
    # the modal could leave a stale value selected. Strip it before
    # save so the FK reflects the chosen kind.
    permitted[:chore_id] = nil unless ChoreGoal::CHORE_SPECIFIC_KINDS.include?(permitted[:kind].to_s.to_sym)
    # awarded_pebbles is the household's payout — only managers can set.
    permitted.delete(:awarded_pebbles) unless current_user.can_manage_chores?
    permitted
  end

  def serialize(goal)
    {
      id:              goal.id,
      name:            goal.name,
      description:     goal.description,
      kind:            goal.kind,
      scope_mode:      goal.scope_mode,
      tracking_mode:   goal.tracking_mode,
      target_value:    goal.target_value,
      awarded_pebbles: goal.awarded_pebbles,
      image_url:       goal.image_url,
      link_url:        goal.link_url,
      chore_id:        goal.chore_id,
      achieved_at:     goal.achieved_at,
      html:            render_to_string(
        partial: "chores/goal_row",
        formats: [:html],
        locals:  { goal: goal },
      ),
    }
  end
end
