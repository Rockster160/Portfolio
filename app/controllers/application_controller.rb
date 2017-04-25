class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception
  helper_method :current_user, :user_signed_in?

  def flash_message
    flash.now[params[:flash_type].to_sym] = params[:message]
    render partial: 'layouts/flashes'
  end

  private

  def unauthorize_user
    if current_user.present?
      redirect_to lists_path, notice: "You're already logged in!"
    end
  end

  def authorize_user
    unless current_user.present?
      session[:forwarding_url] = request.original_url if request.get?
      redirect_to login_path, notice: "You must be logged in to do that!"
    end
  end

  def current_user
    @_current_user ||= begin
      if session[:user_id].present?
        cookies.signed[:user_id] = session[:user_id]
        User.find_by_id(session[:user_id])
      end
    end
  end

  def user_signed_in?
    current_user.present?
  end

  def sign_out
    session[:forwarding_url] = nil
    session[:user_id] = nil
    cookies.signed[:user_id] = nil
    @_current_user = nil
  end

  def sign_in(user)
    sign_out
    session[:user_id] = user.id
    current_user
  end

end
