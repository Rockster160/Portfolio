class Internal::AuthController < ApplicationController
  skip_forgery_protection

  def check
    head(current_user&.admin? ? :ok : :unauthorized)
  end
end
