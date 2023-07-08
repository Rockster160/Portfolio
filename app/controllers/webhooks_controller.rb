class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :post_params, except: [:local_data, :report]
  before_action :skip_without_user, only: [:jil, :command]
  before_action :skip_without_admin, only: [:battery, :local_data, :report, :speak, :tesla_local]

  def jenkins
    head :ok
  end

  def post
    head :ok
  end

  def jil
    ::Jarvis.execute_trigger(
      :webhook,
      params.to_unsafe_h.except(:controller, :action),
      scope: { user: current_user }.tap { |task_scope|
        task_scope[:name] = params[:task_name] if params[:task_name].present?
      }
    )

    head :ok
  end

  def tesla_local
    DataStorage[:tesla_access_token] = params[:access_token]
    DataStorage[:tesla_refresh_token] = params[:refresh_token]
    DataStorage[:tesla_forbidden] = false

    TeslaCommand.quick_command(:reload)

    head :ok
  end

  def google_pub_sub
    SlackNotifier.notify(params.to_unsafe_h)

    head :ok
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

  def battery
    data = params.slice(:Phone, :iPad, :Watch, :Pencil).transform_values { |v|
      { val: v, time: Time.current.to_i }
    }
    json = DataStorage[:device_battery] || {}
    new_data = json.merge(data)
    DataStorage[:device_battery] = new_data
    # -- This will continue to add over and over again until the device is over 50.
    # -- Watch has no way to remove the item.
    # -- Can't monitor if currently charging or not
    # if data.dig(:Phone, :val) <= 50 || data.dig(:Watch, :val) <= 50
    #   @user = User.me
    #   items = []
    #   items << { name: "Charge Phone" } if data.dig(:Phone, :val) <= 50
    #   items << { name: "Charge Watch" } if data.dig(:Watch, :val) <= 50
    #   @user.default_list.add_items(items)
    # end

    ActionCable.server.broadcast(:device_battery_channel, DataStorage[:device_battery])

    head :created
  end

  def local_data
    data = params[:local_data].to_unsafe_h
    json = File.exists?("local_data.json") ? JSON.parse(File.read("local_data.json")) : {}
    File.write("local_data.json", json.merge(data).to_json)
    LocalDataBroadcast.call(data)

    head :created
  end

  def notify
    return head :no_content unless printer_authed?

    ActionCable.server.broadcast :printer_callback_channel, { reload: true }
    PrinterNotify.notify(params)
  end

  def uptime
    if params[:alertTypeFriendlyName] == "Down"
      User.me.list_by_name(:TODO).add("#{params[:monitorFriendlyName]} DOWN")
    else
      User.me.list_by_name(:TODO).remove("#{params[:monitorFriendlyName]} DOWN")
    end

    ::ActionCable.server.broadcast :uptime_channel, {}

    head :no_content
  end

  def report
    gathered = params[:report]&.to_unsafe_h&.each_with_object({}) do |(name, report_data), obj|
      obj[name] = { timestamp: Time.current.to_i }
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
            one: (one.to_f * 100).round,
            five: (five.to_f * 100).round,
            ten: (ten.to_f * 100).round,
          }
        when "cpu"
          obj[name][:cpu] = {
            idle: data.to_i,
          }
        end
      end
    end

    LoadtimeBroadcast.call(gathered)

    head :no_content
  end

  def command
    List.find_and_modify(current_user, params[:command])
  end

  def speak
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

  def skip_without_user
    head :no_content unless user_signed_in?
  end

  def skip_without_admin
    head :no_content unless user_signed_in? && current_user.admin?
  end

  def printer_authed?
    params[:apiSecret] == ENV["PORTFOLIO_PRINTER_SECRET"]
  end

  def post_params
    Rails.logger.warn "#{params.permit!.to_h}"
  end

end
