class QuickActionsController < ApplicationController
  include AuthHelper
  include QuickActionsHelper

  layout "quick_actions"

  skip_before_action :verify_authenticity_token
  before_action :authorize_user

  helper_method :current_user, :user_signed_in?

  def show
    @page = current_user.jarvis_page
  end

  def update
    @page = current_user.jarvis_page
    @page.update(blocks: params.permit!.to_h[:blocks])

    head :ok
  end
end
