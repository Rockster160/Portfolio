# Linked from every Tesla Slack error post so muting/unmuting is one tap
# from a phone. Locked to User.me — anyone else gets 404.
class TeslaSwitchController < ApplicationController
  before_action :require_me

  def show
    apply_param!
    @state = TeslaSwitch.state
  end

  private

  def apply_param!
    case params[:to].to_s
    when "disable" then TeslaSwitch.disable!(reason: params[:reason].presence)
    when "enable"  then TeslaSwitch.enable!
    end
  end

  def require_me
    head :not_found unless current_user&.me?
  end
end
