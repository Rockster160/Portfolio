module AuthHelper
  # Paths that render data rather than a page. Nothing here is somewhere a
  # person can be dropped after logging in.
  NON_PAGE_EXTENSIONS = /\.(json|js|csv|xml|pdf|png|jpe?g|gif|svg|ico|txt|webmanifest|map)\z/i

  def jwt
    return if !user_signed_in? || current_user.guest?

    payload = { user_id: current_user.id, exp: 24.hours.from_now.to_i }
    JWT.encode(payload, Rails.application.secret_key_base, "HS256")
  end

  def jwt_user(token)
    decoded = JWT.decode(token, Rails.application.secret_key_base, true, algorithm: "HS256")
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
    redirect_to previous_url if current_user.present?
  end

  def previous_url(fallback=nil)
    navigable_path(session[:forwarding_url]) || fallback || lists_path
  end

  # Sessions minted before the filter below existed are still carrying data
  # URLs, and a redirect target should never be able to walk off the app.
  def navigable_path(path)
    return if path.blank?
    return unless path.start_with?("/") && !path.start_with?("//")
    return if path.split("?").first.match?(NON_PAGE_EXTENSIONS)

    path
  end

  # Only a real page navigation is somewhere worth coming back to. Background
  # fetches hit the same `authorize_user` filter that pages do, so without this
  # a PWA polling /chores/icons/signature or /agenda/sync/bootstrap while its
  # session lapsed leaves that URL as the post-login destination — and you log
  # in and land on raw JSON.
  def navigable_request?
    return false unless request.get?
    return false if request.xhr?

    # Browsers send Sec-Fetch-Dest on everything; only a top-level document
    # navigation says "document" (fetch and XHR say "empty", frames say
    # "iframe"). Non-browser clients omit it, so absence can't disqualify —
    # the format check below is what carries those.
    dest = request.headers["Sec-Fetch-Dest"]
    return false if dest.present? && dest != "document"

    request.format.html?
  end

  def controller_action
    "#{controller_path}##{action_name}"
  end

  def store_previous_url
    return unless navigable_request? # Only store page navigations
    return if controller_action == "users#account" # Don't store Account page
    # Don't store login pages, or the single-use QR/code pages either side of them
    return if controller_action.match?(%r{^users/(sessions|registrations|device_logins)})
    return if user_signed_in? && !guest_account? # Don't store if already logged in

    session[:forwarding_url] = request.fullpath || request.original_url
  end

  def store_and_login(**msg)
    msg = { notice: "Please sign in before continuing." } if msg.blank?
    store_previous_url
    redirect_to login_path, **msg
  end

  # A guest account is for somebody who has ARRIVED — a page in front of them,
  # with things on it they can act on and nowhere to put the result. A data
  # endpoint reached carrying no session is not an arrival. It is a client whose
  # session lapsed, or one that keeps no session at all, and minting an account
  # for it hands the next write to an empty stranger instead of asking the
  # client to sign in again.
  #
  # `navigable_request?` already draws exactly this line, and its own comment
  # names two of the four endpoints that were doing the minting. One day's
  # crawl: 21,675 guest accounts, and the request that created each one was
  # `/chores/icons.json` 13,235 times, `/agenda/sync/bootstrap` 4,477,
  # `/agenda_preference` 1,421 — every one of them `Sec-Fetch-Dest: empty` or
  # `serviceworker` with `Accept: application/json`. TWO were a page.
  #
  # A real first visit is unaffected: the page navigation mints, and the fetches
  # it fires carry the session it was given. The shared-recipe and playground
  # links that this filter exists for are page navigations and always were.
  def authorize_user_or_guest
    return if current_user.present?
    return head(:unauthorized) unless navigable_request?

    store_previous_url
    create_guest_user

    flash.now[:notice] = "We've signed you up with a guest account!"
  end

  def authorize_user
    if current_user.nil?
      store_previous_url
      return if redirect_to_about_page

      redirect_to login_path, notice: "Please sign in before continuing."
    elsif current_user.guest?
      return if redirect_to_about_page

      redirect_to account_path, notice: "Please finish setting up your account before continuing."
    end
  end

  def authorize_admin
    if current_user.nil?
      store_previous_url
      return if redirect_to_about_page

      redirect_to login_path, notice: "Please sign in before continuing."
    elsif !current_user.admin?
      return if redirect_to_about_page

      redirect_to account_path, alert: "Sorry, you do not have access to this page."
    end
  end

  # A page visit turned away from a Playground project lands on that project's
  # About page, which explains what it is and what opening it takes, rather
  # than a login wall or a bare error. Returns whether it redirected; anything
  # that isn't a page visit, or isn't a project, is left to the caller.
  def redirect_to_about_page # rubocop:disable Naming/PredicateMethod
    return false unless navigable_request?

    project = PlaygroundProject.for_request(request)
    return false if project.nil?

    # About pages live on the main site, not on an app's own subdomain.
    on_app_subdomain = request.subdomain.present? && request.subdomain != "www"
    if on_app_subdomain
      redirect_to playground_project_url(project, subdomain: false), allow_other_host: true
    else
      redirect_to playground_project_path(project)
    end
    true
  end

  def current_user
    @current_user ||= (
      if request.headers["HTTP_AUTHORIZATION"].present?
        auth_from_headers
      else
        auth_from_session
      end
    )
  end

  def create_guest_user
    @user = User.create(role: :guest)

    @auth_type = :guest
    @auth_type_id = @user.id
    sign_in @user
  end

  def sign_out
    session[:user_id] = nil
    session[:current_user_id] = nil
    session.clear

    safe_set_cookie(:user_id, nil)
    safe_set_cookie(:current_user_id, nil)

    @_current_user = nil
  end

  def sign_in(user)
    # Regenerating the session on login clears everything, including the
    # post-login destination the login actions redirect to right after. Carry
    # it across the reset so `redirect_to previous_url` lands where the user was
    # headed instead of falling back to /lists.
    forwarding_url = session[:forwarding_url]
    sign_out
    session[:forwarding_url] = forwarding_url if forwarding_url.present?
    session[:current_user_id] = user.id
    cookies.signed[:current_user_id] = user.id
    @_current_user = user
  end

  def auth_from_headers
    raw_auth = request.headers["HTTP_AUTHORIZATION"]
    return if raw_auth.blank?

    # Had issues where some clients were mixing up bearer vs basic
    # Just made this work for whatever prefix
    type, auth_string = raw_auth.split(" ", 2)

    # Try API key first -  Base64-decoding hex keys can produce false
    # colons, causing them to be misidentified as basic auth
    api_user = ApiKey.authenticate(auth_string)&.tap { |key|
      @auth_type = :api_key
      @auth_type_id = key.id
    }&.user
    return api_user if api_user

    basic_auth_string = Base64.decode64(auth_string.to_s)
    if basic_auth_string.include?(":")
      User.auth_from_basic(basic_auth_string)&.tap { |user|
        @auth_type = :userpass
        @auth_type_id = user.id
      }
    end
  rescue ActiveRecord::StatementInvalid
    ApiKey.authenticate(auth_string)&.tap { |key|
      @auth_type = :api_key
      @auth_type_id = key.id
    }&.user
  end

  def safe_cookie(key)
    return if cookies.nil?

    begin
      cookies.signed[key].presence || cookies.permanent[key].presence
      # There is a crazy bug right now where our cookies got messed up and are returning nil
    rescue NoMethodError
      #   cookies[key] rescue nil
    end
  end

  def safe_set_cookie(key, value)
    return if cookies.nil?

    begin
      cookies.signed[key] = value
      cookies.permanent[key] = value
    rescue NoMethodError
      #   (cookies[key] = value) rescue nil
    end
  end

  def auth_from_session
    current_user_id = (
      session[:current_user_id].presence || safe_cookie(:current_user_id).presence ||
      session[:user_id].presence || safe_cookie(:user_id).presence
    )

    if current_user_id.present?
      user = User.find_by(id: current_user_id)
      return sign_out if user.nil?

      session[:current_user_id] = current_user_id
      safe_set_cookie(:current_user_id, current_user_id)
      user
    end
  end

  def current_ip
    @current_ip ||= request.try(:remote_ip) || request.env["HTTP_X_REAL_IP"] || request.env["REMOTE_ADDR"]
  end
end
