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
    blob = request.try(:raw_post).to_s
    json = JSON.parse(JSON.parse(blob)&.dig("Message")) || {}
    action = json.dig("receipt", "action") || {}
    bucket = action["bucketName"]
    filename = action["objectKey"]

    ReceiveEmailWorker.perform_async(bucket, filename)

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

  def report
    return head :no_content unless user_signed_in?

    gathered = params[:report]&.to_unsafe_h&.each_with_object({}) do |(name, report_data), obj|
      obj[name] = {}
      report_data.each do |key, data|
        case key
        when "memory"
          # ["Mem:", "3951", "1103", "1100", "143", "1748", "2405"]
          _, total, used, free, shared, buff, available = data.split(/\s+/)
          obj[name][:memory] = {
            used: used.to_i,
            free: free.to_i,
            total: total.to_i,
          }
        when "load"
          # 0.03 0.03 0.00 1/196 4114
          one, five, ten, pids, _ = data.split(/\s+/)
          obj[name][:load] = {
            one: one.to_i,
            five: five.to_i,
            ten: ten.to_i,
          }
        when "cpu"
          # 04:47:35 AM  CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
          # 04:47:35 AM  all    1.29    0.00    0.38    0.17    0.00    0.02    0.01    0.00    0.00   98.13
          time, md, sect, usr, nice, sys, io, irq, soft, steal, guest, gnice, idle = data.split(/\s+/)
          obj[name][:cpu] = {
            idle: idle.to_i,
          }
        end
      end
    end

    LoadtimeBroadcast.call(gathered)

    head :no_content
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
