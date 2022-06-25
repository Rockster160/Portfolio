class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception
  helper_method :current_user, :user_signed_in?, :guest_account?
  before_action :see_current_user, :logit
  before_action :show_guest_banner, if: :guest_account?

  def flash_message
    flash.now[params[:flash_type].to_sym] = params[:message]
    render partial: 'layouts/flashes'
  end

  private

  def guest_account?
    current_user&.guest?
  end

  def show_guest_banner
    @show_guest_banner = true
  end

  def see_current_user
    Rails.logger.silence do
      session[:forwarding_url] = request.original_url if request.get?
      if user_signed_in?
        current_user.see!
        request.env['exception_notifier.exception_data'] = { current_user: current_user }
      end
    end
  end

  def logit
    return CustomLogger.log_blip! if params[:checker]

    CustomLogger.log_request(request, current_user)
  end

  def unauthorize_user
    if current_user.present?
      redirect_to lists_path
    end
  end

  def previous_url(fallback=nil)
    session[:forwarding_url] || fallback || lists_path
  end

  def authorize_user
    unless current_user.present?
      create_guest_user

      flash.now[:notice] = "We've signed you up with a guest account!"
    end
  end

  def authorize_admin
    unless current_user.try(:admin?)
      redirect_to login_path
    end
  end

  def current_user
    @_current_user ||= begin
      if request.headers["HTTP_AUTHORIZATION"].present?
        auth_from_headers
      else
        auth_from_session
      end
    end
  end

  def create_guest_user
    @user = User.create(role: :guest)

    sign_in @user
  end

  def user_signed_in?
    current_user.present?
  end

  def sign_out
    session[:user_id] = nil
    cookies.signed[:user_id] = nil
    session[:current_user_id] = nil
    cookies.signed[:current_user_id] = nil
    cookies.permanent[:current_user_id] = nil
    @_current_user = nil
  end

  def sign_in(user)
    sign_out
    session[:current_user_id] = user.id
    cookies.signed[:current_user_id] = user.id
    current_user
  end

  def auth_from_headers
    basic_auth_raw = request.headers["HTTP_AUTHORIZATION"][6..-1] # Strip "Basic " from hash
    return unless basic_auth_raw.present?

    basic_auth_string = Base64.decode64(basic_auth_raw)
    User.auth_from_basic(basic_auth_string)
  end

  def auth_from_session
    current_user_id = session[:current_user_id].presence || cookies.signed[:current_user_id].presence || cookies.permanent[:current_user_id].presence || session[:user_id].presence || cookies.signed[:user_id].presence

    if current_user_id.present?
      session[:current_user_id] = current_user_id
      cookies.signed[:current_user_id] = current_user_id
      cookies.permanent[:current_user_id] = current_user_id
      user = User.find_by_id(current_user_id)
      sign_out if user.nil?
      user
    end
  end

end
