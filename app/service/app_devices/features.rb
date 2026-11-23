module AppDevices
  # Everything the phone app can do beyond showing the site, with the options
  # each one takes and the Jil triggers its data arrives under. The device page
  # renders straight from this.
  #
  # A `permission` feature needs iOS to allow it first. It can only be switched
  # on once the phone has asked and been allowed; after that it is configured
  # here like any other.
  module Features
    Feature = Struct.new(
      :key,
      :title,
      :info,
      :permission,
      :options,
      :triggers,
      :tasks,
      :tests,
      keyword_init: true,
    )
    Option = Struct.new(
      :key,
      :type,
      :label,
      :info,
      :choices,
      :minimum,
      :maximum,
      :step,
      :source,
      keyword_init: true,
    )
    Trigger = Struct.new(:key, :summary, :example, keyword_init: true)
    Task = Struct.new(:key, :label, :info, keyword_init: true)
    # A push sent from the page to show that part works on the phone.
    Check = Struct.new(:key, :label, :info, keyword_init: true)

    # What each server channel sends to the phone as a notification.
    PUSH_CHANNELS = {
      byte:    "Buddy",
      timers:  "Timers",
      agenda:  "Agenda",
      chores:  "Chores",
      whisper: "Whisper",
      jarvis:  "Jarvis",
    }.freeze
    LOCATION_MODES = {
      significant: "Significant",
      balanced:    "Balanced",
      continuous:  "Continuous",
    }.freeze

    def self.option(key, type, label, info, **)
      Option.new(key: key, type: type, label: label, info: info, **)
    end

    def self.trigger(key, summary, example)
      Trigger.new(key: key, summary: summary, example: example)
    end

    def self.task(key, label, info)
      Task.new(key: key, label: label, info: info)
    end

    def self.check(key, label, info)
      Check.new(key: key, label: label, info: info)
    end

    ALL = [
      Feature.new(
        key:        :push,
        title:      "Push notifications",
        info:       "The server can send notifications to this phone, for the kinds picked below.",
        permission: true,
        options:    [
          option(
            :push_badges,
            :boolean,
            "Unread count",
            "The app icon shows how many Buddy messages are unread, and their notifications " \
            "clear once they're read anywhere.",
          ),
          option(
            :native_push_replaces_web_push,
            :boolean,
            "Turn off web push",
            "The kinds picked below stop going to the home-screen web app and browsers, so " \
            "each notification arrives once, here.",
          ),
          option(
            :open_links_in_app,
            :boolean,
            "Open links in the app",
            "Pages a widget, hot link or notification opens, like a list or the agenda, open " \
            "inside this app. Off, they open in Safari or their own home-screen app.",
          ),
          option(
            :push_channels,
            :channels,
            "Notify for",
            "The kinds of notifications this phone gets. One left off still goes to the web " \
            "app and browsers.",
            choices: PUSH_CHANNELS,
          ),
        ],
        tests:      [
          check(:alert, "Test notification", "Sends a notification to this phone."),
          check(
            :badge,
            "Test unread count",
            "Puts a 1 on the app icon. Opening the app clears it.",
          ),
        ],
      ),
      Feature.new(
        key:      :actionable_notifications,
        title:    "Notification buttons",
        info:     "A notification shows the buttons its message carries, like Yes or Snooze, so " \
                  "it can be answered from the Lock Screen. Each press fires the trigger below.",
        triggers: [
          trigger(
            :ios_notification_action,
            "A button was pressed",
            "ios_notification_action:action::yes",
          ),
        ],
      ),
      Feature.new(
        key:     :live_activities,
        title:   "Live Activities",
        info:    "A running timer or alarm counts down on the Lock Screen and in the Dynamic " \
                 "Island.",
        options: [
          option(
            :live_activities_for_timers,
            :boolean,
            "Timers",
            "A running timer counts down on the Lock Screen and in the Dynamic Island.",
          ),
          option(
            :live_activities_for_alarms,
            :boolean,
            "Alarms",
            "An alarm counts down on the Lock Screen and in the Dynamic Island.",
          ),
          option(
            :live_activities_push_to_start,
            :boolean,
            "Start when the app is closed",
            "A timer started somewhere else, like in Buddy, shows here right away. Off, it " \
            "shows the next time the app opens.",
          ),
        ],
        tasks:   [
          task(
            :test_live_activity,
            "Test Live Activity",
            "Counts down a minute on this phone's Lock Screen. Nothing rings, and it shows " \
            "nowhere else.",
          ),
        ],
      ),
      Feature.new(
        key:        :alarms,
        title:      "Alarms",
        info:       "Timers and alarms ring the way the Clock app's do: full screen, through " \
                    "silent mode and Focus.",
        permission: true,
        options:    [
          option(:alarms_ring_alarms, :boolean, "Alarms", "Alarms ring full screen."),
          option(
            :alarms_ring_timers,
            :boolean,
            "Timers",
            "Timers ring full screen. Off, a finished timer is a notification.",
          ),
        ],
      ),
      Feature.new(
        key:      :hot_links,
        title:    "Hot links",
        info:     "Buttons in the Hot Links widget, the app icon's long-press menu and the " \
                  "Shortcuts app. One list for every phone, edited under Hot links.",
        triggers: [
          trigger(:ios_hot_link, "A trigger hot link was pressed", "ios_hot_link:name::Garage"),
        ],
      ),
      Feature.new(
        key:   :widgets,
        title: "Widgets",
        info:  "Home Screen and Lock Screen widgets for lists, the agenda, chore boards, " \
               "buttons, charts and hot links. Refresh redraws them now.",
        tasks: [task(:refresh_widgets, "Refresh", "Redraws every widget on this phone now.")],
      ),
      Feature.new(
        key:      :quick_commands,
        title:    "Offline queue",
        info:     "Commands and messages sent from widgets, Shortcuts and hot links wait on the " \
                  "phone with no signal, then send in order once it's back.",
        options:  [
          option(
            :commands_show_confirmations,
            :boolean,
            "Show when it sends",
            "After a hot link runs from the app, a banner at the top says Sent, or Queued when " \
            "there's no signal.",
          ),
        ],
        triggers: [
          trigger(:tell, "A queued command", "tell:/log water/"),
          trigger(:ios_command, "Any command from the app", "ios_command:source::widget"),
        ],
      ),
      Feature.new(
        key:      :battery,
        title:    "Battery",
        info:     "Sends this phone's battery level and whether it's charging each time either " \
                  "changes.",
        options:  [
          option(
            :battery_writes_dashboard,
            :boolean,
            "Dashboard battery",
            "This phone's level shows in the dashboard's battery cell.",
          ),
        ],
        triggers: [
          trigger(
            :ios_battery,
            "Level or charging changed",
            "ios_battery:device::phone charging:true",
          ),
        ],
        tasks:    [
          task(
            :send_battery,
            "Send now",
            "Sends the battery level now instead of on its next change.",
          ),
        ],
      ),
      Feature.new(
        key:        :bluetooth_battery,
        title:      "Bluetooth batteries",
        info:       "Sends the battery level of connected Bluetooth accessories that report one, " \
                    "like headphones.",
        permission: true,
        triggers:   [
          trigger(:ios_battery, "An accessory's level changed", "ios_battery:name:AirPods"),
        ],
      ),
      Feature.new(
        key:        :location,
        title:      "Location",
        info:       "Sends this phone's position so Jil tasks can act on where you are.",
        permission: true,
        options:    [
          option(
            :location_mode,
            :select,
            "Updates",
            "Significant: after moving about 500 m, the lightest on the battery. Balanced: " \
            "about every 100 m while moving. Continuous: GPS-accurate, the heaviest on the " \
            "battery.",
            choices: LOCATION_MODES,
          ),
          option(
            :location_visits,
            :boolean,
            "Visits",
            "Arriving at and leaving anywhere you stay a while, as iOS notices it.",
          ),
          option(
            :location_regions,
            :boolean,
            "Saved places",
            "Arriving at and leaving Home and contact addresses with a label, the closest 20.",
          ),
          option(
            :location_feeds_travel,
            :boolean,
            "Travel",
            "Each arrival and departure also fires the travel trigger, the same as one from a " \
            "Shortcut.",
          ),
          option(
            :location_minimum_meters,
            :number,
            "Minimum move (m)",
            "A position closer than this to the last one sent isn't sent.",
            minimum: 25,
            maximum: 2000,
            step:    25,
          ),
        ],
        triggers:   [
          trigger(:ios_location, "A new position", "ios_location:kind::move"),
          trigger(:ios_location, "Arrived or left", "ios_location:kind::visit action::arrived"),
          trigger(
            :ios_location,
            "A saved place",
            "ios_location:kind::region action::departed place::Home",
          ),
          trigger(:trytravel, "Arrivals and departures", "travel:action::arrived"),
        ],
      ),
      Feature.new(
        key:        :health,
        title:      "Workouts",
        info:       "Sends each workout saved to Apple Health: its type, duration, calories, " \
                    "distance and heart rate.",
        permission: true,
        options:    [
          option(
            :health_logs_workout_event,
            :boolean,
            "Log as a Workout event",
            "Each workout is also logged as a Workout event, alongside the ones logged by hand.",
          ),
          option(
            :health_daily_totals,
            :boolean,
            "Daily totals",
            "Once a day, yesterday's steps, active calories, exercise minutes and sleep.",
          ),
        ],
        triggers:   [
          trigger(:ios_workout, "A workout was saved", "ios_workout:type::running"),
          trigger(:event, "Logged as a Workout event", "event:name::Workout"),
          trigger(:ios_health, "Daily totals", "ios_health:kind::daily"),
        ],
        tasks:      [
          task(:check_workouts, "Check now", "Sends any workouts saved since the last check."),
        ],
      ),
      Feature.new(
        key:        :calendar,
        title:      "Calendar",
        info:       "Sends the events in this phone's calendars, then each one added, changed or " \
                    "deleted.",
        permission: true,
        options:    [
          option(
            :calendar_days_back,
            :number,
            "Days back",
            "How far into the past events are sent.",
            minimum: 0,
            maximum: 60,
            step:    1,
          ),
          option(
            :calendar_days_ahead,
            :number,
            "Days ahead",
            "How far into the future events are sent.",
            minimum: 1,
            maximum: 365,
            step:    1,
          ),
          option(
            :calendar_identifiers,
            :sources,
            "Calendars",
            "The calendars that are sent. None picked sends all of them.",
            source: :calendars,
          ),
        ],
        triggers:   [trigger(:ios_calendar, "An event changed", "ios_calendar:action::added")],
        tasks:      [
          task(:sync_calendar, "Sync", "Sends the events changed since the last sync."),
          task(
            :resend_calendar,
            "Resend all",
            "Sends every event again, as if none had been sent.",
          ),
        ],
      ),
      Feature.new(
        key:        :reminders,
        title:      "Reminders",
        info:       "Sends the reminders in this phone's Reminders lists, then each change.",
        permission: true,
        options:    [
          option(
            :reminders_include_completed,
            :boolean,
            "Include completed",
            "Completed reminders are sent too. Off, only open ones are, and one checked off " \
            "arrives as completed.",
          ),
          option(
            :reminder_list_identifiers,
            :sources,
            "Lists",
            "The lists that are sent. None picked sends all of them.",
            source: :reminder_lists,
          ),
        ],
        triggers:   [
          trigger(
            :ios_reminders,
            "A reminder changed",
            "ios_reminders:action::completed list::Groceries",
          ),
        ],
        tasks:      [
          task(:sync_reminders, "Sync", "Sends the reminders changed since the last sync."),
        ],
      ),
      Feature.new(
        key:        :contacts,
        title:      "Contacts",
        info:       "Sends this phone's contacts, then each one added, changed or deleted.",
        permission: true,
        triggers:   [trigger(:ios_contacts, "A contact changed", "ios_contacts:action::updated")],
        tasks:      [
          task(:sync_contacts, "Sync", "Sends the contacts changed since the last sync."),
          task(
            :resend_contacts,
            "Resend all",
            "Sends every contact again, as if none had been sent.",
          ),
        ],
      ),
      Feature.new(
        key:      :share,
        title:    "Share sheet",
        info:     "Adds Buddy to the share sheet, sending a link, text or photo to Jil.",
        triggers: [trigger(:ios_share, "Sent to Jil", "ios_share:kind::url")],
      ),
    ].map { |feature|
      feature.options ||= []
      feature.triggers ||= []
      feature.tasks ||= []
      feature.tests ||= []
      feature.permission = !!feature.permission
      feature.freeze
    }.freeze

    KEYS = ALL.map(&:key).freeze
    PERMISSION_KEYS = ALL.select(&:permission).map(&:key).freeze
    OPTIONS = ALL.flat_map(&:options).index_by(&:key).freeze
    TASKS = ALL.flat_map(&:tasks).map(&:key).freeze
    CHECKS = ALL.flat_map(&:tests).map(&:key).freeze

    def self.find(key)
      ALL.find { |feature| feature.key == key.to_s.to_sym }
    end
  end
end
