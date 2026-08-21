# The other end of a Slack::Actions link. Locked to User.me, like
# TeslaSwitchController — the link carries no secret of its own, so the session
# is what stands between a forwarded message and somebody else's controls.
class SlackActionsController < ApplicationController
  before_action :require_me

  def show
    @name = params[:name]
    @status, @said = Slack::Actions.call(@name, action_params)
  end

  private

  def action_params
    params.except(:controller, :action, :name).permit!.to_h.symbolize_keys
  end

  def require_me
    head :not_found unless current_user&.me?
  end
end
