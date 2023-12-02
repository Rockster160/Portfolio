class QuickActionsController < ::ActionController::Base
  include AuthHelper
  include QuickActionsHelper
  skip_before_action :verify_authenticity_token
  helper_method :current_user, :user_signed_in?
  layout "quick_actions"

  before_action :redirect_to_login

  def show
    @page = current_user.jarvis_page
  end

  def update
    @page = current_user.jarvis_page
    @page.update(blocks: params.permit!.to_h[:blocks])

    head :ok
  end

  private

  def redirect_to_login
    session[:forwarding_url] = request.original_url
    redirect_to login_path if current_user.blank?
  end
end
