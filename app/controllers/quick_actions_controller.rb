class QuickActionsController < ::ActionController::Base
  include AuthHelper
  helper_method :current_user, :user_signed_in?
  layout "quick_actions"

  before_action :redirect_to_login

  private

  def redirect_to_login
    redirect_to login_path if current_user.blank?
  end
end
