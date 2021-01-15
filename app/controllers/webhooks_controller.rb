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

  def notify
    return head :no_content if printer_secret?

    PrinterNotify.notify(params)
  end

  def command
    return head :no_content unless user_signed_in?

    List.find_and_modify(current_user, params[:command])
  end

  def push_notification_subscribe
    return render(json: { data: :failure }, status: :ok) if params[:sub_auth].blank?

    push_sub = UserPushSubscription.find_by(sub_auth: params[:sub_auth])

    push_data = { endpoint: params[:endpoint] }.merge(params.permit(keys: [:auth, :p256dh])[:keys])
    push_sub&.update(push_data)

    render json: { data: push_sub.as_json.except(:created_at, :updated_at) }, status: :ok
  end

  private

  def printer_secret?
    params[:apiSecret] == ENV["PORTFOLIO_PRINTER_SECRET"]
  end

  def post_params
    Rails.logger.warn "#{params.permit!.to_h}"
  end

end
