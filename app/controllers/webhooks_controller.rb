class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :post_params

  def jenkins
    head 200
  end

  def post
    head 200
  end

  def email
    Email.receive(request)

    head :no_content
  end

  def local_data
    return head :no_content unless user_signed_in? && current_user.admin?

    data = params[:local_data].to_unsafe_h
    File.write("local_data.json", data.to_json)
    LocalDataBroadcast.call(data)

    head :created
  end

  def notify
    return head :no_content unless printer_authed?

    ActionCable.server.broadcast "printer_callback_channel", { reload: true }
    PrinterNotify.notify(params)
  end

  def command
    return head :no_content unless user_signed_in?

    List.find_and_modify(current_user, params[:command])
  end

  def speak
    return head :no_content unless user_signed_in?

    SmsWorker.perform_async("3852599640", params[:text])
  end

  def push_notification_subscribe
    return render(json: { data: :failure }, status: :ok) if params[:sub_auth].blank?

    push_sub = UserPushSubscription.find_by(sub_auth: params[:sub_auth])

    push_data = { endpoint: params[:endpoint] }.merge(params.permit(keys: [:auth, :p256dh])[:keys])
    push_sub&.update(push_data)

    render json: { data: push_sub.as_json.except(:created_at, :updated_at) }, status: :ok
  end

  private

  def printer_authed?
    params[:apiSecret] == ENV["PORTFOLIO_PRINTER_SECRET"]
  end

  def post_params
    Rails.logger.warn "#{params.permit!.to_h}"
  end

end
