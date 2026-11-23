class Api::Ios::DevicesController < Api::Ios::BaseController
  FIELDS = [
    :name,
    :apns_token,
    :apns_environment,
    :widget_push_token,
    :app_version,
    :os_version,
    :timezone,
  ].freeze

  def show
    render json: current_device.serialize
  end

  # Tokens and what the phone is, plus what iOS allows. Features and options
  # are set on the site; the phone only reports, and asks to turn a feature on
  # when it has just been allowed it.
  def update
    attrs = params.permit(*FIELDS).to_h
    if params[:push_to_start_tokens].respond_to?(:permit!)
      attrs[:push_to_start_tokens] = current_device.push_to_start_tokens.to_h.merge(
        params[:push_to_start_tokens].permit!.to_h,
      ).compact_blank
    end
    release_token(attrs[:apns_token])
    current_device.assign_attributes(attrs)

    current_device.report!(
      permissions: params[:permissions].respond_to?(:permit!) ? params[:permissions].permit!.to_h : nil,
      sources:     params[:sources].respond_to?(:permit!) ? params[:sources].permit!.to_h : nil,
      turn_on:     params[:turn_on],
    )
    render json: current_device.serialize
  end

  def test_push
    kind = params[:kind].to_s.presence || "alert"
    result = current_device.test_push!(kind, user: current_user)
    render json: { kind: kind, result: result&.to_h }
  end

  private

  # A push token belongs to one install. A reinstall signs in as a new
  # device with the same token, and the old row would otherwise push to it
  # too, so every notification would arrive twice.
  def release_token(token)
    return if token.blank?

    others = AppDevice.where(apns_token: token).where.not(id: current_device.id)
    others.update_all(apns_token: nil) # rubocop:disable Rails/SkipsModelValidations
  end
end
