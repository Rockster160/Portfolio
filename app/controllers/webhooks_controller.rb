class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :post_params, except: [:report]
  before_action :none_unless_user, only: [:execute_task, :jil, :command]
  before_action :none_unless_admin, only: [:battery, :report, :speak, :tesla_local]
  skip_before_action :pretty_logit, only: [:report] # Lots of data here

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
    # if params[:issuer] == "https://auth.tesla.com/oauth2/v3"
    #   # FIXME: Should look up the user based on issuer or secret or something...
    #   ::TeslaControl.me.code = params[:code]
    # end

    case params[:service].to_s.to_sym
    when :spotify_api
      ::Oauth::SpotifyApi.from_jwt(params[:state])&.code = params[:code] if params[:code].present?
    when :google_api
      # Google bounces the user back here after consent. Always end on the
      # connect page — either ready to pick calendars (happy path) or with
      # a clear error flash so the user knows to retry.
      api = ::Oauth::GoogleApi.from_jwt(params[:state])
      if params[:error].present?
        flash[:alert] = "Google connection cancelled: #{params[:error]}"
      elsif api.blank?
        flash[:alert] = "Google connection failed — please try again."
      elsif params[:code].blank?
        flash[:alert] = "Google didn't return an authorization code — please try again."
      else
        api.code = params[:code]
      end
      return redirect_to(new_agenda_connection_path)
    end

    render json: params
  end

  # /jil/webhook
  def command
  end

  # /jil/webhook
  def jil_webhook
    json_params.each do |key, data|
      jil_trigger(key, data)
    end

    head :ok
  end

  # /jil/trigger/:trigger?
  def jil
    if params.key?(:trigger)
      jil_trigger(
        params[:trigger],
        json_params[:data].presence || json_params.except(:trigger),
      )
    else
      json_params.each do |trigger, data|
        jil_trigger(trigger, data)
      end
    end

    head :ok
  end

  # /webhooks/jil
  def execute_task
    task = current_user.tasks.active.enabled.find_by(uuid: params[:uuid])

    if task.present?
      exe = task.match_run(
        :webhook, { params: json_params },
        force: true, auth: jil_auth_type, auth_id: jil_auth_id
      )

      if exe.nil?
        render json: {
          data:   nil,
          task:   nil,
          notice: "Task found, but input data does not match listener.",
        }
      else
        render json: { data: task.last_result, task: task.serialize_with_execution }
      end
    else
      render json: { data: nil, task: nil, notice: "No task found by that uuid." },
        status: :not_found
    end
  end

  def tesla_local
    api = ::Oauth::TeslaApi.new(User.me)
    api.access_token = params[:access_token] if params[:access_token].present?
    api.refresh_token = params[:refresh_token] if params[:refresh_token].present?
    DataStorage[:tesla_forbidden] = false

    TeslaCommand.quick_command(:reload)
    ::PrettyLogger.info("[Reloaded Tesla Connection]")

    head :ok
  end

  def tesla_telemetry
    unless request.local? || request.remote_ip == "127.0.0.1"
      return head :forbidden
    end

    TeslaTelemetry.process(json_params)
    head :ok
  end

  def google_pub_sub
    SlackNotifier.notify(params.to_unsafe_h)

    head :ok
  end

  # Receiver for Google Calendar events.watch push notifications.
  # Google identifies the channel via headers — there's no body to parse:
  #   X-Goog-Channel-Id        → matches `agendas.watch_channel_id`
  #   X-Goog-Channel-Token     → must equal our derived HMAC for that agenda
  #   X-Goog-Resource-State    → "sync" on the initial handshake; otherwise
  #                              "exists" / "not_exists" for change deliveries
  # Always replies 200 quickly — the actual sync is enqueued.
  def google_calendar
    channel_id = request.headers["X-Goog-Channel-Id"].presence
    token = request.headers["X-Goog-Channel-Token"].presence
    resource_state = request.headers["X-Goog-Resource-State"].to_s
    return head :no_content if channel_id.blank?

    agenda = ::Agenda.google.find_by(watch_channel_id: channel_id)
    return head :no_content if agenda.nil?
    return head :forbidden if token != ::GoogleCalendar::WatchManager.token_for(agenda)

    # The "sync" handshake is just Google confirming we're listening — no
    # change to apply. Enqueue a real sync only for content-state deliveries.
    return head :no_content if resource_state == "sync"

    ::GoogleCalendarSyncWorker.perform_async(agenda.id)
    head :no_content
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
    data = params.slice(:Phone, :iPad, :Watch, :Pencil, :Trackpad).transform_values { |v|
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

  def local_ping
    return head :ok unless current_user == User.me

    LocalIpManager.local_ip = request.remote_ip

    head :ok
  end

  def uptime
    if params[:alertTypeFriendlyName] == "Down"
      User.me.list_by_name(:TODO).add("#{params[:monitorFriendlyName]} DOWN")
    else
      User.me.list_by_name(:TODO).remove("#{params[:monitorFriendlyName]} DOWN")
    end

    ::Jil.trigger(User.me, :monitor, { channel: :uptime, refresh: true })

    head :no_content
  end

  def report
    now = Time.current.to_i
    stamped = (params[:report]&.to_unsafe_h || {}).transform_values { |data|
      data.is_a?(Hash) ? data.merge(timestamp: now) : data
    }

    ::Jil.trigger(User.me, :monitor, { channel: :uptime, report: stamped })

    head :no_content
  end

  def list_command
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
    channel = params[:channel].presence || :jarvis

    # One subscription per user per channel - find by channel only, update endpoint if changed
    push_sub = current_user.push_subs.find_or_initialize_by(channel: channel)
    push_sub.assign_attributes({
      endpoint:      params[:endpoint],
      registered_at: Time.current,
      **keys,
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

  def push_notification_unsubscribe
    return head :ok unless user_signed_in?

    channel = params[:channel].presence || :jarvis
    push_sub = current_user.push_subs.find_by(channel: channel)

    if push_sub
      push_sub.update(registered_at: nil)
      Rails.logger.info("[WEBPUSH] Unsubscribed #{current_user.username} from #{channel}")
    end

    head :ok
  end

  def push_diagnostic
    user = current_user&.username || "anonymous"
    event = params[:event]
    permission = params[:permission]
    opted_out = params[:optedOut]
    error = params[:error]
    timestamp = params[:timestamp]

    Rails.logger.error("[PUSH_DIAG] #{user} | #{event} | permission=#{permission} | optedOut=#{opted_out} | error=#{error} | #{timestamp}")
    head :ok
  end

  private

  def json_params
    return @json_params if defined?(@json_params)

    json = params.to_unsafe_h.except(:controller, :action)
    return (@json_params = json) unless json.keys.length == 2 # uuid and broken json

    json_key = json.except(:uuid).keys.first
    return (@json_params = json) unless json[json_key].nil?

    @json_params = json.except(json_key).merge(JSON.parse(json_key, symbolize_names: true))
  rescue JSON::ParserError
    @json_params = json
  end

  def none_unless_user
    head :no_content unless user_signed_in?
  end

  def none_unless_admin
    head :no_content unless user_signed_in? && current_user.admin?
  end

  def post_params
    ::Rails.logger.warn(params.permit!.to_h.to_s)
  end
end
