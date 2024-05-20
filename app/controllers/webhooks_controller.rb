class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :post_params, except: [:local_data, :report]
  before_action :none_unless_user, only: [:jil, :command]
  before_action :none_unless_admin, only: [:battery, :local_data, :report, :speak, :tesla_local]
  skip_before_action :pretty_logit, only: [:local_data, :report]

  def jenkins
    head :ok
  end

  def post
    head :ok
  end

  def auth
    # params[:service] # tesla_api, venmo_api, etc...
    # Find the Oauth for the issuer or other token, then find the current_user (maybe signed in?)
    # ::Oauth::MyApi.new(current_user).code = params[:code]
    if params[:issuer] == "https://auth.tesla.com/oauth2/v3"
      # FIXME: Should look up the user based on issuer or secret or something...
      ::TeslaControl.me.code = params[:code]
    end

    render json: params
  end

  def jil
    res = ::Jarvis.execute_trigger(
      :webhook,
      params.to_unsafe_h.except(:controller, :action),
      scope: { user_id: current_user.id }.tap { |task_scope|
        task_scope[:name] = params[:task_name] if params[:task_name].present?
        task_scope[:id] = params[:id] if params[:id].present?
      }
    )

    if res.none?
      render json: { error: "No webhooks found with that id" }
    elsif res.many?
      render json: { data: res[..-2] } # Remove "Success" from the end
    else
      render json: { data: res.first }
    end
  end

  def tesla_local
    DataStorage[:tesla_access_token] = params[:access_token]
    DataStorage[:tesla_refresh_token] = params[:refresh_token]
    DataStorage[:tesla_forbidden] = false

    TeslaCommand.quick_command(:reload)
    LocalIpManager.local_ip = request.remote_ip
    ::PrettyLogger::BaseLogger.info("[Reloaded Tesla Connection]")

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
    json = DataStorage[:local_data] || {}
    DataStorage[:local_data] = json.merge(data)
    LocalDataBroadcast.call(data)
    LocalIpManager.local_ip = request.remote_ip

    head :created
  end

  def local_ping
    LocalIpManager.local_ip = request.remote_ip

    head :ok
  end

  def notify
    return head :no_content unless printer_authed?

    LocalIpManager.local_ip = request.remote_ip
    ActionCable.server.broadcast(:printer_callback_channel, { printer_data: params.permit!.to_h.except(:apiSecret) })
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
        when "latency"
          obj[name][:latency] = {
            seconds: data.to_i,
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
    Rails.logger.info("Received subscription request! [#{current_user&.username}] (#{request.headers["JarvisPushVersion"].inspect})")
    return head :ok unless request.headers["JarvisPushVersion"].to_s == "2"
    # return head :ok unless request.headers["UserJWT"].present?
    # user = jwt_user(request.headers["UserJWT"])
    Rails.logger.info("Sub version 2! #{current_user&.username}")
    return head :ok if !user_signed_in? || current_user.guest?

    Rails.logger.info("Signed in!")
    keys = params.permit(keys: [:auth, :p256dh])[:keys].slice(:auth, :p256dh)

    push_sub = current_user.push_subs.find_or_initialize_by(endpoint: params[:endpoint])
    push_sub.assign_attributes({
      registered_at: Time.current,
      **keys
    })
    Rails.logger.info("Initialized!")

    if push_sub.save
      Rails.logger.info("Saved!")
      head :ok
    else
      Rails.logger.warn("\e[31mERROR:\e[0m #{push_sub.errors.full_messages}")
      render json: { errors: push_sub.errors.full_messages }, status: :bad_request
    end
  end

  private

  def none_unless_user
    head :no_content unless user_signed_in?
  end

  def none_unless_admin
    head :no_content unless user_signed_in? && current_user.admin?
  end

  def printer_authed?
    params[:apiSecret] == ENV["PORTFOLIO_PRINTER_SECRET"]
  end

  def post_params
    Rails.logger.warn "#{params.permit!.to_h}"
  end

end
