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
    when :tesla_api
      # OAuth redirect for Tesla. Decode state JWT to find the bound user
      # (will only succeed for state values that were signed by THIS env's
      # secret — dev-signed states fall through and the wizard handles them
      # by code paste). Exchange routes through the home relay via the
      # overridden code= in Oauth::TeslaApi, then clears the disabled flag.
      api = ::Oauth::TeslaApi.from_jwt(params[:state])
      if api && params[:code].present?
        api.code = params[:code]
        if api.access_token.present?
          ::DataStorage[:tesla_forbidden] = false
          flash[:notice] = "Tesla connected — access_token cached."
        else
          flash[:alert] = "Tesla rejected the auth code."
        end
        return redirect_to(root_path)
      end
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
        result = (api.code = params[:code])
        if result.nil? || api.google_account.blank?
          flash[:alert] = "Google rejected the connection — please try again."
        else
          flash[:notice] = "Connected #{api.google_account.email} — pick which calendars to bring in below."
        end
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

    expected = ::GoogleCalendar::WatchManager.token_for(agenda)
    return head :forbidden unless token && expected && ::ActiveSupport::SecurityUtils.secure_compare(token, expected)

    # The "sync" handshake is just Google confirming we're listening — no
    # change to apply. Enqueue a real sync only for content-state deliveries.
    return head :no_content if resource_state == "sync"

    ::GoogleCalendarSyncWorker.perform_async(agenda.id, "webhook")
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

  # Callback from the local Mac Byte server. Two entry points; both
  # authenticate via X-Byte-Secret and accept either JSON or
  # multipart/form-data (files[] for attachments).
  #
  # POST /webhooks/byte         — create a new inbound message
  # PATCH /webhooks/byte/:id    — update an existing message
  #                                     (streaming chunks, late attachments,
  #                                     terminal state transitions)
  #
  # Simple JSON POST still works exactly as before:
  #   { "user_id": 1, "body": "hi" }
  #
  # Multipart adds files:
  #   files[]=@chart.png, files[]=@log.txt
  #
  # Update accepts a subset of fields; metadata merges (never replaces).
  def byte_create
    return head :unauthorized unless byte_authorized?

    user_id = params[:user_id].presence || User.me.id
    user = User.find_by(id: user_id)
    return head :not_found if user.blank?

    body     = params[:body].to_s
    files    = Array(params[:files]).compact_blank
    metadata = byte_metadata(params)
    metadata[:in_reply_to] = params[:in_reply_to] if params[:in_reply_to].present?

    return head :bad_request if body.empty? && files.empty?

    state = (params[:state].presence || :delivered).to_sym
    state = :delivered unless ByteMessage.states.key?(state.to_s)

    conversation = byte_resolve_conversation(user)

    message = conversation.byte_messages.create!(
      user:         user,
      direction:    :inbound,
      state:        state,
      body:         body,
      metadata:     metadata,
      delivered_at: (state == :delivered ? Time.current : nil),
    )
    message.files.attach(files) if files.any?

    # NOTE: Buddy processing lives in byte_update, not here — this endpoint
    # fires on the initial "..." streaming placeholder before the reply
    # exists. Processing here would flip the pet expression too early.
    byte_broadcast(user, message)
    byte_notify(user, message)

    render json: message.as_wire, status: :ok
  end

  def byte_update
    return head :unauthorized unless byte_authorized?

    message = ByteMessage.find_by(id: params[:id])
    return head :not_found if message.blank?

    if params.key?(:body)
      message.body = params[:body].to_s
    end

    if params[:state].present?
      new_state = params[:state].to_sym
      if ByteMessage.states.key?(new_state.to_s)
        message.state = new_state
        message.delivered_at = Time.current if new_state == :delivered && message.delivered_at.blank?
      end
    end

    if params[:metadata].present?
      # Merge, don't replace — other writers' fields must survive.
      incoming = byte_metadata(params)
      message.metadata = (message.metadata || {}).merge(incoming.stringify_keys)
    end

    message.save!

    if params[:files].present?
      message.files.attach(Array(params[:files]).compact_blank)
    end

    # Optional re-timestamp: Claude turns that spawned action-request cards
    # (permission / plan / question) get created BEFORE those cards, so
    # they sort above them in the thread. Bumping `created_at` on finalize
    # slots the response after everything that happened during the turn.
    if params[:touch_created_at].present?
      message.update_column(:created_at, Time.current)
    end

    # Buddy marker/mood/expression processing runs HERE (on finalize), not
    # in byte_create — the initial byte_create fires with body "..." from
    # the streaming placeholder, which would prematurely flip the pet to
    # :neutral before Buddy has even replied. Only fire when the message
    # settles to :delivered and belongs to a buddy conversation.
    if message.state == "delivered" && message.saved_change_to_state? && message.byte_conversation&.buddy?
      buddy_process_reply(message.user, message.byte_conversation, message)
    end

    # Detect Anthropic usage-cap errors coming back through the failed-
    # message path. Mac's error text includes "out of usage / resets X".
    # If we can parse a reset time, flip the user to sleeping and rewrite
    # the body to the friendly in-character sleeping reply so the user
    # sees "Byte is sleeping" instead of the raw error.
    if message.byte_conversation&.buddy? && %w[failed delivered].include?(message.state)
      reset_at = ::Buddy::SleepGuard.parse_reset_time(message.body, default_tz: message.user.timezone)
      if reset_at
        ::Buddy::SleepGuard.sleep_until!(message.user, reset_at)
        message.update!(
          body:     ::Buddy::SleepGuard.sleeping_reply_body(message.user),
          state:    :delivered,
          metadata: (message.metadata || {}).merge("kind" => "buddy", "source" => "sleep_guard"),
        )
      end
    end

    byte_broadcast(message.user, message)
    byte_notify(message.user, message) if message.state == "delivered" && message.saved_change_to_state?

    render json: message.as_wire, status: :ok
  end

  # Mac (or any other originator) creates a Byte action-request. Persists
  # the ByteAction record, creates the accompanying action-request message
  # in the target conversation, broadcasts it, and returns the wire form
  # so the caller can correlate its blocking wait with the request_id.
  def byte_create_action
    return head :unauthorized unless byte_authorized?

    user_id = params[:user_id].presence || User.me.id
    user    = User.find_by(id: user_id)
    return head :not_found if user.blank?

    convo = byte_resolve_conversation(user)
    return head :not_found if convo.nil?

    incoming    = byte_metadata(params)
    request_id  = params[:request_id].presence || SecureRandom.uuid
    kind        = normalized_action_kind(params[:kind])
    tool_name   = params[:tool_name].to_s.presence
    tool_input  = byte_json_field(params[:tool_input]) || {}
    buttons     = byte_json_field(params[:buttons]) || []
    # For AskUserQuestion, the hook forwards a structured `questions`
    # array so the client can render stacked sections (one per question).
    # Falls back to nil when the action is a plain permission/plan.
    questions   = byte_json_field(params[:questions])
    multi       = ActiveModel::Type::Boolean.new.cast(params[:multi_select])
    expires_at  = parse_expiry(params[:expires_in], params[:expires_at])

    action = ByteAction.create!(
      user:              user,
      byte_conversation: convo,
      request_id:        request_id,
      kind:              kind,
      tool_name:         tool_name,
      tool_input:        tool_input,
      buttons:           buttons,
      multi_select:      !!multi,
      expires_at:        expires_at,
    )

    message = convo.byte_messages.create!(
      user:         user,
      direction:    :inbound,
      state:        :delivered,
      body:         params[:body].to_s,
      metadata:     {
        kind:              :"action-request",
        action_request_id: request_id,
        action_kind:       kind.to_s,
        action_state:      :pending,
        tool_name:         tool_name,
        tool_input:        tool_input,
        buttons:           buttons,
        questions:         questions,
        multi_select:      !!multi,
        title:             params[:title].to_s.presence,
        subtitle:          params[:subtitle].to_s.presence,
        expires_at:        expires_at&.iso8601(3),
      }.compact.merge(incoming.symbolize_keys.except(:action_state)),
      delivered_at: Time.current,
    )
    action.update!(byte_message_id: message.id)

    MonitorChannel.broadcast_to(user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire },
    })

    # Action requests (permission, plan, question) are TIME-SENSITIVE —
    # Claude is blocked waiting for the user's tap. If the user has
    # walked away from Byte, push a notification so they know to come
    # back. byte_notify itself checks presence and skips when the user
    # is currently in-app.
    byte_notify(user, message)

    render json: {
      request_id: action.request_id,
      message_id: message.id,
      action:     action.as_wire,
    }, status: :created
  end

  # Mac → Rails conversation metadata update (e.g. cwd changed after cd,
  # claude_session_id changed after /adopt). Secret-auth like the other
  # byte webhooks; performs a MERGE (not replace) so multi-writer keys
  # coexist.
  def byte_update_conversation
    return head :unauthorized unless byte_authorized?

    convo = ByteConversation.find_by(id: params[:id])
    return head :not_found if convo.nil?

    if params[:metadata].present?
      incoming = byte_metadata(params).stringify_keys
      convo.update!(metadata: (convo.metadata || {}).merge(incoming))
    end

    if params[:name].present?
      convo.update!(name: params[:name].to_s.strip)
    end

    MonitorChannel.broadcast_to(convo.user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :conversation, event: :updated, conversation: convo.as_wire },
    })

    render json: convo.as_wire
  end

  # Read-only agenda lookup for Buddy. Accepts either a symbolic `range`
  # (today / tomorrow / weekend / week / upcoming) or a free-form `q`
  # (mirrors AgendaItem search syntax). Returns a compact text summary
  # that the LLM can drop straight into a reply — pre-formatted in the
  # user's timezone as 12h AM/PM so we don't rely on the model to do
  # timezone math (it gets it wrong).
  def byte_agenda
    return head :unauthorized unless byte_authorized?

    user = User.find_by(id: params[:user_id].presence || User.me.id)
    return head :not_found if user.blank?

    scope = AgendaItem.where(agenda_id: user.accessible_agendas.select(:id))
    label = byte_agenda_scope(scope, user, params[:range], params[:q])
    return render json: { error: :"unknown range" }, status: :bad_request if label.nil?

    items = label[:scope].order(:start_at).limit(50)
    lines = items.map { |it| byte_format_agenda_line(it, user) }
    body  = lines.empty? ? "no items in that range." : lines.join("\n")

    render json: { range: label[:name], count: items.length, body: body }
  end

  # The mirror of byte_create: a message FROM the person, injected from off-web
  # (the Mac `tell` CLI, a cron job, a Jil bash step). byte_create posts as
  # Byte; this posts as them and gets a real Buddy turn back, exactly as if
  # they'd typed it in the PWA — same stash capture, same timer fast path, same
  # sleep queue, because it goes through the same ByteMessageIntake.
  #
  # Targets their default Buddy conversation unless `conversation_id` says
  # otherwise. Refuses a non-Buddy conversation: a CLI has no business steering
  # a claude/bash thread on the Mac that spawned it.
  def byte_say
    return head :unauthorized unless byte_authorized?

    user = User.find_by(id: params[:user_id].presence || User.me.id)
    return head :not_found if user.blank?

    conversation = byte_say_conversation(user)
    return render json: { error: :"no buddy conversation" }, status: :not_found if conversation.nil?
    return render json: { error: :"not a buddy conversation" }, status: :unprocessable_entity unless conversation.buddy?

    message = ByteMessageIntake.call(
      user:         user,
      conversation: conversation,
      body:         params[:body].to_s,
      metadata:     byte_metadata(params).symbolize_keys.reverse_merge(source: :cli),
    )
    return render json: { error: :"empty body" }, status: :bad_request if message.nil?

    render json: message.as_wire, status: :created
  end

  # Explicit id wins; otherwise their most recent Buddy thread, falling back to
  # the default. `ByteConversation.default_for` can hand back a claude thread
  # for the owner, which is not what "send this to Byte" means.
  def byte_say_conversation(user)
    id = params[:conversation_id].presence
    return user.byte_conversations.find_by(id: id) if id

    user.byte_conversations.where(mode: :buddy, archived: false).order(last_message_at: :desc).first ||
      ByteConversation.default_for(user)
  end

  # Weather passthrough for Buddy — server holds WEATHER_APIKEY.
  # No location param support yet: uses the home coords the dashboard
  # already uses. Returns a compact one-liner suitable for chat.
  def byte_weather
    return head :unauthorized unless byte_authorized?

    body = WeatherService.summary
    return render json: { error: :"weather unavailable" }, status: :service_unavailable if body.blank?

    render json: { body: body }
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

  # Buddy replies no longer arrive through this controller — they are built,
  # streamed, and finalized in-process by Buddy::GPT::Turn, which owns tool
  # dispatch, proposal building, and expression settling.
  #
  # This remains only as a safety net for a Buddy-conversation message that
  # somehow lands via the Mac webhook (a stale Mac process still holding a
  # message id from before the cutover). It settles the pet so the thinking
  # overlay can't stick, and says so loudly in the log.
  def buddy_process_reply(_user, _conversation, message)
    conversation = message.byte_conversation
    Rails.logger.warn(
      "[Buddy] reply arrived via the Mac webhook for conversation=#{conversation.id} " \
      "message=#{message.id}. Buddy runs in Rails now; this path should be dead.",
    )
    Buddy::ExpressionState.settle!(conversation)
  rescue StandardError => e
    Rails.logger.warn("[Buddy] reply-processing failed: #{e.class}: #{e.message}")
    # Even on error, don't leave the pet frozen thinking forever.
    Buddy::ExpressionState.settle!(message.byte_conversation) rescue nil
  end

  def normalized_action_kind(raw)
    sym = raw.to_s.downcase.to_sym
    ByteAction.kinds.key?(sym.to_s) ? sym : :permission
  end

  def byte_json_field(raw)
    return raw if raw.is_a?(Array) || raw.is_a?(Hash)
    return raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)

    JSON.parse(raw.to_s) rescue nil
  end

  def parse_expiry(expires_in, expires_at)
    if expires_at.present?
      Time.zone.parse(expires_at.to_s) rescue nil
    elsif expires_in.present?
      expires_in.to_i.seconds.from_now
    end
  end

  def byte_agenda_scope(base, user, range, query)
    q = query.to_s.strip
    return { name: q, scope: AgendaItem.query(q).where(id: base.select(:id)) } if q.present?

    now       = Time.current
    tz        = user.timezone
    zone_now  = now.in_time_zone(tz)
    case range.to_s.downcase.presence || "upcoming"
    when "today"
      { name: :today, scope: base.where(start_at: zone_now.all_day) }
    when "tomorrow"
      day = zone_now.tomorrow
      { name: :tomorrow, scope: base.where(start_at: day.all_day) }
    when "weekend"
      # This coming Sat/Sun in the user's TZ. If today is Sat, "weekend"
      # means today + tomorrow; if Sun, just today.
      sat   = zone_now.next_occurring(:saturday)
      sat   = zone_now.beginning_of_day if [6, 0].include?(zone_now.wday)
      sun   = sat + 1.day
      start = [zone_now, sat.beginning_of_day].max
      finish = sun.end_of_day
      { name: :weekend, scope: base.where(start_at: start..finish) }
    when "week"
      finish = (zone_now + 7.days).end_of_day
      { name: :week, scope: base.where(start_at: zone_now..finish) }
    when "upcoming"
      { name: :upcoming, scope: base.upcoming.where(start_at: ...(zone_now + 14.days)) }
    end
  end

  def byte_format_agenda_line(item, user)
    tz = user.timezone
    start = item.start_at&.in_time_zone(tz)
    return "- #{item.name} (no time)" if start.nil?

    stamp = start.strftime("%a %-m/%-d %-I:%M %p")
    parts = ["#{stamp}  #{item.name}"]
    parts << "@ #{item.location}" if item.location.present?
    "- #{parts.join("  ")}"
  end

  def byte_authorized?
    ByteLocal.valid_secret?(request.headers["X-Byte-Secret"])
  end

  # Prefer an explicit conversation_id (Mac echoes back what we passed
  # forward). If absent, look up an in_reply_to → find that message's
  # conversation. Absolute fallback: the user's default conversation.
  def byte_resolve_conversation(user)
    convo_id = params[:conversation_id].presence
    if convo_id
      convo = user.byte_conversations.find_by(id: convo_id)
      return convo if convo
    end

    reply_id = params[:in_reply_to].presence
    if reply_id
      parent = user.byte_messages.find_by(id: reply_id)
      return parent.byte_conversation if parent&.byte_conversation
    end

    ByteConversation.default_for(user)
  end

  def byte_metadata(params)
    raw = params[:metadata]
    return {} if raw.blank?
    return raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    return raw if raw.is_a?(Hash)

    JSON.parse(raw.to_s) rescue {}
  end

  def byte_broadcast(user, message)
    MonitorChannel.broadcast_to(user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: message.as_wire },
    })
  end

  # Extracted to ByteNotifier so the in-Rails Buddy turn — which never routes
  # through this controller — pushes with identical framing and presence rules.
  def byte_notify(user, message)
    ByteNotifier.notify(user, message)
  end

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
