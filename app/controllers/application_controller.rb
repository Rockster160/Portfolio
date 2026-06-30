class ApplicationController < ActionController::Base
  include SerializeHelper, AuthHelper

  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception, if: -> {
    current_user&.id != 1
  } # Hack- skip CSRF if it's me
  helper_method :current_user, :user_signed_in?, :guest_account?

  # skip_before_action :pretty_logit # Defined by gem
  # before_action :pretty_logit, if: -> { user_signed_in? } # Only log for signed in users
  before_action :tracker, :see_current_user
  before_action :show_guest_banner, if: :guest_account?
  prepend_before_action :block_banned_ip

  around_action :use_timezone

  after_action { session.delete(:forwarding_url) if current_user.present? }

  rescue_from ::ActiveRecord::RecordNotFound, with: :rescue_login
  rescue_from ::ActionDispatch::Http::Parameters::ParseError, with: :rescue_bad_params

  if Rails.env.production?
    rescue_from ::ActionController::InvalidAuthenticityToken, with: :handle_stale_csrf
    rescue_from ::ActionController::UnknownHttpMethod, with: :under_rug
    rescue_from ::ActionDispatch::Http::MimeNegotiation::InvalidType, with: :under_rug
    rescue_from ::ActionController::ParameterMissing, with: :under_rug
  end

  def flash_message
    flash.now[params[:flash_type].to_sym] = params[:message]
    render partial: "layouts/flashes"
  end

  private

  def jil_trigger(scope, data={})
    Jil.trigger(current_user, scope, data, auth: jil_auth_type, auth_id: jil_auth_id)
  end

  def jil_auth_type
    return @auth_type if @auth_type
    return :trigger if current_user.blank?

    current_user.guest? ? :guest : :userpass
  end

  def jil_auth_id
    @auth_type_id || current_user&.id
  end

  def tracker
    return if params[:checker]
    return if Rails.env.test?

    ::TrackerLogger.log_request(request, current_user)
  end

  def see_current_user
    Rails.logger.silence {
      store_previous_url

      if user_signed_in?
        current_user.see!
        request.env["exception_notifier.exception_data"] = {
          current_user: current_user,
          params:       params,
        }
      end
    }
  end

  def current_ip_spamming?
    LogTracker.where(ip_address: current_ip).where(created_at: 30.seconds.ago...).count >= 5
  end

  def ip_whitelisted?
    BannedIp.where(ip: current_ip, whitelisted: true).any?
  end

  def ban_spam_ip(exception)
    if !ip_whitelisted? && current_ip_spamming?
      BannedIp.find_or_create_by(ip: current_ip)
      SlackNotifier.notify("Banned: #{current_ip}")
    end

    raise exception
  end

  # PWAs hold pages open for days; CSRF tokens rotate with the session
  # under them. The mutation queue already recovers on 422 by refetching
  # the csrf endpoint and retrying — but if we let the exception escape,
  # every stale-token POST also hits ExceptionNotifier and Slacks.
  # Render 422 cleanly so legit stale tokens stay silent; escalate only
  # when the same user keeps hitting it (i.e., client recovery is
  # actually broken, not just a one-off rotation).
  def handle_stale_csrf(exception)
    if !ip_whitelisted? && current_ip_spamming?
      BannedIp.find_or_create_by(ip: current_ip)
      SlackNotifier.notify("Banned: #{current_ip}")
      raise exception
    end

    notify_if_stuck(exception)

    respond_to do |format|
      format.json { render json: { error: "stale_csrf" }, status: :unprocessable_entity }
      format.any  { head :unprocessable_entity }
    end
  end

  # Count stale-CSRF hits per user across a short window. A normal
  # recovery is a single 422 → /<csrf endpoint> → success, so one hit.
  # If a real user logs 3+ within a minute, their client is not
  # recovering — surface to Slack (throttled to once per user per 10m
  # so we know without flooding).
  def notify_if_stuck(exception)
    user = current_user
    return if user.nil? || user.id == 1

    count_key = "csrf_stale_count:user:#{user.id}"
    alert_key = "csrf_stale_alerted:user:#{user.id}"
    count = Rails.cache.increment(count_key, 1, expires_in: 60.seconds, initial: 0) || 1
    return if count < 3
    return if Rails.cache.exist?(alert_key)

    Rails.cache.write(alert_key, true, expires_in: 10.minutes)
    SlackNotifier.notify(
      "`#{user.username}` is hitting stale CSRF repeatedly on " \
      "`#{request.method} #{request.path}` — client recovery isn't working " \
      "(exception: `#{exception.class}`).",
    )
  end

  def rescue_login
    store_and_login
  end

  def under_rug
    head :unauthorized
  end

  def block_banned_ip
    head :unauthorized if BannedIp.where(ip: current_ip, whitelisted: false).any?
  end

  def rescue_bad_params
    render(
      json:   {
        error:  "The request params are in an unexpected format. Please try again with valid JSON.",
        params: request.body.read(1005).truncate(1000),
      },
      status: :unprocessable_entity,
    )
  end

  def use_timezone
    Time.use_zone(current_user&.timezone || User.timezone) {
      yield if block_given?
    }
  end
end
