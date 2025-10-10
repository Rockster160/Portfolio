module AuthHelpers
  def sign_in(user)
    # Use controller's session and cookies in controller specs
    session[:current_user_id] = user.id
    if respond_to?(:cookies) && cookies.respond_to?(:signed)
      cookies.signed[:current_user_id] = user.id
    elsif respond_to?(:cookies)
      cookies[:current_user_id] = user.id
    end
  end
end

RSpec.configure do |config|
  config.include AuthHelpers, type: :controller
end
