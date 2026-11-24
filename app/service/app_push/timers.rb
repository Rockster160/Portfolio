module AppPush
  # Keeps a countdown's Live Activity on each phone in step with the timer, and
  # tells the app about it so it can ring it through AlarmKit.
  #
  # Start goes out as a push-to-start, which works with the app closed. Apple
  # hands each started activity its own update token, which the app registers
  # (AppLiveActivity); until it has, a placeholder row stops a second start.
  module Timers
    module_function

    ATTRIBUTES_TYPE = "TimerActivityAttributes".freeze
    # How long an ended activity stays on the Lock Screen.
    LINGER = 5.minutes

    def sync(timer, reason)
      return unless timer&.countdown?

      ::Buddy::Timers.audience(timer).each { |user|
        AppPush.devices(user, feature: :live_activities).each { |device|
          sync_activity(device, timer, reason)
        }
        AppPush.devices(user, feature: :alarms).each { |device|
          AppPush.deliver_to(
            device,
            AppPush.background(timer: wire(timer).merge(reason: reason.to_s)),
            push_type: :background,
          )
        }
      }
    end

    # The timer is deleted, so who could see it is no longer known: every phone
    # in its owner's household that rings alarms checks its list again.
    def gone(timer_id, user_id=nil)
      household = User.find_by(id: user_id)&.chore_household_user_ids
      User.where(id: household.to_a).find_each { |user|
        AppPush.devices(user, feature: :alarms).each { |device|
          changed = AppPush.background(timers_changed: true)
          AppPush.deliver_to(device, changed, push_type: :background)
        }
      }
      AppLiveActivity.for_ref(:timer, timer_id).includes(:app_device).find_each { |activity|
        if activity.push_token.present?
          Apns.deliver(
            token:        activity.push_token,
            payload:      { aps: {
              timestamp:        Time.current.to_i,
              event:            :end,
              "content-state":  { name: "Timer", state: :done },
              "dismissal-date": Time.current.to_i,
            } },
            environment:  activity.app_device.apns_environment,
            push_type:    :liveactivity,
            topic_suffix: "push-type.liveactivity",
          )
        end
        activity.end!
      }
    end

    def sync_activity(device, timer, reason)
      return unless wanted?(device, timer)

      activities = AppLiveActivity.for_ref(:timer, timer.id).where(app_device: device)
      state = state_of(timer)

      if state == :done
        activities.each { |activity|
          push_activity(device, activity, timer, event: :end) if activity.push_token.present?
          activity.end!
        }
      elsif activities.any?
        activities.select { |a| a.push_token.present? }.each { |activity|
          push_activity(device, activity, timer, event: :update, alert: state == :fired)
        }
      elsif state == :running && device.preference?(:live_activities_push_to_start)
        start(device, timer)
      end
    rescue StandardError => e
      Rails.logger.warn("[APP_PUSH] timer #{timer&.id} (#{reason}): #{e.class}: #{e.message}")
    end

    def wanted?(device, timer)
      alarm = timer.metadata.to_h["alarm"].present?
      device.preference?(alarm ? :live_activities_for_alarms : :live_activities_for_timers)
    end

    def start(device, timer)
      token = device.push_to_start_tokens.to_h["timer"]
      return if token.blank?

      AppLiveActivity.create!(
        app_device:  device,
        activity_id: "pts:#{device.id}:#{timer.id}:#{SecureRandom.hex(4)}",
        kind:        :timer,
        ref_id:      timer.id.to_s,
      )
      result = Apns.deliver(
        token:        token,
        payload:      { aps: aps(timer, event: :start).merge(
          "attributes-type": ATTRIBUTES_TYPE,
          attributes:        attributes(timer),
          alert:             { title: timer.name.presence || "Timer", body: "Started" },
        ) },
        environment:  device.apns_environment,
        push_type:    :liveactivity,
        topic_suffix: "push-type.liveactivity",
      )
      if result.dead_token?
        device.update(push_to_start_tokens: device.push_to_start_tokens.except("timer"))
      end
      result
    end

    def push_activity(device, activity, timer, event:, alert: false)
      body = aps(timer, event: event)
      body[:"dismissal-date"] = (Time.current + LINGER).to_i if event == :end
      if alert
        title = timer.name.presence || "Timer"
        body[:alert] = { title: title, body: "Time's up", sound: AppPush.sound_file(timer.alert_sound) }
      end
      result = Apns.deliver(
        token:        activity.push_token,
        payload:      { aps: body },
        environment:  device.apns_environment,
        push_type:    :liveactivity,
        topic_suffix: "push-type.liveactivity",
      )
      activity.end! if result.dead_token?
      result
    end

    def aps(timer, event:)
      {
        timestamp:         Time.current.to_i,
        event:             event.to_s,
        "content-state":   content_state(timer),
        "relevance-score": relevance(timer),
      }
    end

    # Which of a phone's timers iOS puts in the Dynamic Island, highest first:
    # one ringing, then the running one that ends soonest, then the paused ones.
    # The app scores its own updates the same way (ContentState.relevance).
    def relevance(timer)
      case state_of(timer)
      when :fired then 20_000_000_000
      when :running then timer.end_at ? 10_000_000_000 - timer.end_at.to_f : 1
      else 1
      end
    end

    def attributes(timer)
      {
        timer_id: timer.id,
        name:     timer.name.presence || "Timer",
        icon:     timer.metadata.to_h["icon"].presence,
        color:    timer.color,
        kind:     kind(timer),
      }.compact
    end

    def content_state(timer)
      {
        name:             timer.name.presence || "Timer",
        ends_at:          timer.end_at&.to_f,
        started_at:       timer.started_at&.to_f,
        paused_remaining: timer.paused? ? timer.paused_remaining_ms.to_i / 1000.0 : nil,
        state:            state_of(timer).to_s,
      }.compact
    end

    def state_of(timer)
      return :done if timer.archived_at.present?
      return :fired if timer.fired? && timer.confirmed_at.nil?
      return :paused if timer.paused?
      return :running if timer.running?

      :done
    end

    def alarm?(timer) = timer.metadata.to_h["alarm"].present?

    def kind(timer)
      return :alarm if alarm?(timer)
      return :wait if ::Buddy::Timers.wait?(timer)

      :timer
    end

    # The shape the app reads, everywhere a timer is described to it.
    def wire(timer)
      {
        id:               timer.id,
        name:             timer.name.presence || "Timer",
        kind:             kind(timer),
        icon:             timer.metadata.to_h["icon"].presence,
        color:            timer.color,
        ends_at:          timer.end_at&.iso8601(3),
        started_at:       timer.started_at&.iso8601(3),
        paused_remaining: timer.paused? ? timer.paused_remaining_ms.to_i / 1000.0 : nil,
        state:            state_of(timer),
        sound:            timer.alert_sound,
        url:              "/timers",
      }
    end
  end
end
