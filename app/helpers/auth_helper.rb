module AuthHelper
  def jwt
    return if !user_signed_in? || current_user.guest?

    payload = { user_id: current_user.id, exp: 24.hours.from_now.to_i }
    JWT.encode(payload, Rails.application.secrets.secret_key_base, "HS256")
  end

  def jwt_user(token)
    decoded = JWT.decode(token, Rails.application.secrets.secret_key_base, true, algorithm: "HS256")
    return unless decoded.is_a?(Array) && decoded.first.is_a?(Hash)

    decoded.first["user_id"].presence&.then { |id|
      @auth_type = :jwt
      @auth_type_id = id
      User.find(id)
    }
  end

  def guest_account?
    current_user&.guest?
  end

  def user_signed_in?
    current_user.present?
  end

  def show_guest_banner
    @show_guest_banner = true
  end

  def unauthorize_user
    if current_user.present?
      redirect_to previous_url
    end
  end

  def previous_url(fallback=nil)
    session[:forwarding_url] || fallback || lists_path
  end

  def controller_action
    "#{controller_name}##{action_name}"
  end

  def store_previous_url
    return unless request.get? # Only store GET requests
    return if controller_action == "users#account" # Don't store Account page
    return if controller_action.match?(/^users\/(sessions|registrations)/) # Don't store login pages
    return if user_signed_in? && !guest_account? # Don't store if already logged in

    session[:forwarding_url] = request.fullpath || request.original_url
  end

  def store_and_login(**msg)
    msg = { notice: "Please sign in before continuing." } if msg.blank?
    store_previous_url
    redirect_to login_path, **msg
  end

  def authorize_user_or_guest
    unless current_user.present?
      store_previous_url
      create_guest_user

      flash.now[:notice] = "We've signed you up with a guest account!"
    end
  end

  def authorize_user
    if current_user.nil?
      store_previous_url
      redirect_to login_path, notice: "Please sign in before continuing."
    elsif current_user.guest?
      redirect_to account_path, notice: "Please finish setting up your account before continuing."
    end
  end

  def authorize_admin
    if current_user.nil?
      store_previous_url
      redirect_to login_path, notice: "Please sign in before continuing."
    elsif !current_user.admin?
      redirect_to account_path, alert: "Sorry, you do not have access to this page."
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

    @auth_type = :guest
    @auth_type_id = @user.id
    sign_in @user
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

    # Had issues where some clients were mixing up bearer vs basic
    # Just made this work for whatever prefix
    type, auth_string = raw_auth.split(" ", 2)
    basic_auth_string = Base64.decode64(auth_string.to_s)

    if basic_auth_string.include?(":")
      User.auth_from_basic(basic_auth_string)&.tap { |user|
        @auth_type = :username
        @auth_type_id = user.id
      }
    else
      ApiKey.find_by(key: auth_string)&.tap { |key|
        @auth_type = :api_key
        @auth_type_id = key.id
        key.use!
      }&.user
    end
  rescue ActiveRecord::StatementInvalid # Sometimes decoding the auth string can result in weirdness
    ApiKey.find_by(key: auth_string)&.tap { |key|
      @auth_type = :api_key
      @auth_type_id = key.id
      key.use!
    }&.user
  end

  def auth_from_session
    current_user_id = (
      session[:current_user_id].presence ||
      (cookies && cookies.signed[:current_user_id].presence) ||
      (cookies && cookies.permanent[:current_user_id].presence) ||
      session[:user_id].presence ||
      (cookies && cookies.signed[:user_id].presence)
    )

    if current_user_id.present?
      session[:current_user_id] = current_user_id
      cookies && cookies.signed[:current_user_id] = current_user_id
      cookies && cookies.permanent[:current_user_id] = current_user_id
      user = User.find_by_id(current_user_id)
      sign_out if user.nil?
      user
    end
  end

  def current_ip
    @current_ip ||= request.try(:remote_ip) || request.env['HTTP_X_REAL_IP'] || request.env['REMOTE_ADDR']
  end
end
