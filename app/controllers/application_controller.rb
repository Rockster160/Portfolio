class ApplicationController < ActionController::Base
  include AuthHelper
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception, if: -> { current_user&.id != 1 } # Hack- skip CSRF if it's me
  helper_method :current_user, :user_signed_in?, :guest_account?

  # skip_before_action :pretty_logit # Defined by gem
  # before_action :pretty_logit, if: -> { user_signed_in? } # Only log for signed in users
  before_action :tracker, :see_current_user
  before_action :show_guest_banner, if: :guest_account?
  prepend_before_action :block_banned_ip

  rescue_from ::ActiveRecord::RecordNotFound, with: :rescue_login

  if Rails.env.production?
    rescue_from ::ActionController::InvalidAuthenticityToken, with: :ban_spam_ip
    rescue_from ::ActionController::UnknownHttpMethod, with: :under_rug
    rescue_from ::ActionDispatch::Http::MimeNegotiation::InvalidType, with: :under_rug
    rescue_from ::ActionController::ParameterMissing, with: :under_rug
  end

  def flash_message
    flash.now[params[:flash_type].to_sym] = params[:message]
    render partial: 'layouts/flashes'
  end

  private

  def tracker
    return if params[:checker]

    ::TrackerLogger.log_request(request, current_user)
  end

  def see_current_user
    Rails.logger.silence do
      store_previous_url

      if user_signed_in?
        current_user.see!
        request.env['exception_notifier.exception_data'] = {
          current_user: current_user,
          params: params
        }
      end
    end
  end

  def controller_action
    "#{params[:controller]}##{params[:action]}"
  end

  def previous_url(fallback=nil)
    session.delete(:forwarding_url) || fallback || lists_path
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

  def rescue_login
    store_and_login
  end

  def under_rug
    head :unauthorized
  end

  def block_banned_ip
    head :unauthorized if BannedIp.where(ip: current_ip, whitelisted: false).any?
  end
end
