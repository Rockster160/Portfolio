class Internal::AuthController < ApplicationController
  skip_forgery_protection
  before_action :authorize_admin

  def check
    head(current_user&.admin? ? :ok : :unauthorized)
  end
end
