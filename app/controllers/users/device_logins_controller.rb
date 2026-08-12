class Users::DeviceLoginsController < ApplicationController
  before_action :authorize_user, only: [:show]

  # Every visit mints a fresh credential and retires the last one, so the
  # "New code" link is just this page again.
  def show
    @device_login = DeviceLoginToken.issue!(current_user)
    @claim_url    = device_login_claim_url(@device_login.token)
    # A standalone SVG leads with an XML prologue, which is not valid inline in
    # an HTML document — the <svg> element on its own is. Keep from <svg on.
    @qr_svg = Qr.to_svg(@claim_url, level: :m, module_size: 8)[/<svg\b.*/m]
  end

  def claim
    user = DeviceLoginToken.claim_token(params[:token])

    if user.nil?
      return redirect_to(
        login_path,
        alert: "That sign-in link has already been used or expired. Generate a new one and try again.",
      )
    end

    sign_in user
    redirect_to root_path, notice: "Signed in as #{user.username}."
  end
end
