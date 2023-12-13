module AuthHelper
  def guest_account?
    current_user&.guest?
  end

  def show_guest_banner
    @show_guest_banner = true
  end

  def unauthorize_user
    if current_user.present?
      redirect_to lists_path
    end
  end

  def authorize_user
    unless current_user.present?
      session[:forwarding_url] = request.original_url
      create_guest_user

      flash.now[:notice] = "We've signed you up with a guest account!"
    end
  end

  def authorize_admin
    unless current_user.try(:admin?)
      session[:forwarding_url] = request.original_url
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
    @_current_user = user
  end

  def auth_from_headers
    raw_auth = request.headers["HTTP_AUTHORIZATION"]
    return unless raw_auth.present?

    if raw_auth.starts_with?("Basic ")
      basic_auth_string = Base64.decode64(raw_auth[6..-1]) # Strip "Basic " from hash
      User.auth_from_basic(basic_auth_string)
    elsif raw_auth.starts_with?("Bearer ")
      ApiKey.find_by(key: raw_auth[7..-1])&.user
    end
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

  def current_ip
    @current_ip ||= request.try(:remote_ip) || request.env['HTTP_X_REAL_IP'] || request.env['REMOTE_ADDR']
  end
end
