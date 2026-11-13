# Serves a HomeScreenIcon record's install manifest and icon. Both are fetched
# by the browser without cookies, so the record is found by the signed install
# token in the URL, and only when it is the record the path names.
module HomeScreenInstall
  extend ActiveSupport::Concern

  private

  def find_installed(klass)
    record = klass.from_install_token(params[:t])
    record if record && record.to_param == params[:id].to_s
  end

  def render_install_manifest(record, **)
    render json: record.install_manifest(**), content_type: "application/manifest+json"
  end

  # The URL carries the record's updated_at, so a long cache is never a stale
  # icon.
  def send_home_screen_icon(record)
    return head(:not_found) unless record.icon?

    expires_in 1.year, public: true
    send_data record.icon_png, type: "image/png", disposition: :inline
  end
end
