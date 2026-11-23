class Api::Ios::SessionsController < Api::Ios::BaseController
  def destroy
    current_device.revoke!
    render json: { ok: true }
  end

  # Puts the device's person into a web session and goes on to `to`, so the
  # app's web view opens signed in, remembering which phone it is for the
  # app's own pages. Only a path on this site, or one of its subdomains, is
  # followed.
  def web_session
    sign_in(current_user)
    cookies.permanent.signed[:app_device_id] = { value: current_device.id, domain: :all, tld_length: 2 }
    render_redirect(params[:to].to_s)
  end

  private

  def render_redirect(target)
    return redirect_to(target.start_with?("/") ? target : "/") unless target.match?(%r{\Ahttps?://})

    uri = URI.parse(target) rescue nil
    base = request.host.sub(/\A(www|byte)\./, "")
    allowed = uri&.host.present? && (uri.host == base || uri.host.end_with?(".#{base}"))
    allowed ? redirect_to(target, allow_other_host: true) : redirect_to("/")
  end
end
