class QuickActionsController < ::ActionController::Base
  include AuthHelper
  helper_method :current_user, :user_signed_in?
  layout "quick_actions"
end
