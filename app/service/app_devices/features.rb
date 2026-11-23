module AppDevices
  # Everything the phone app can do beyond showing the site, with the options
  # each one takes and the Jil triggers its data arrives under. The device page
  # renders straight from this.
  #
  # A `permission` feature needs iOS to allow it first. It can only be switched
  # on once the phone has asked and been allowed; after that it is configured
  # here like any other.
  module Features
    Feature = Struct.new(:key, :title, :permission, :options, :triggers, :tasks, :tests, keyword_init: true)
    Option = Struct.new(:key, :type, :label, :choices, :minimum, :maximum, :step, :source, keyword_init: true)
    Trigger = Struct.new(:key, :summary, :example, keyword_init: true)
    Task = Struct.new(:key, :label, keyword_init: true)

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

    def self.option(key, type=:boolean, label=nil, **)
      Option.new(key: key, type: type, label: label, **)
    end

    def self.trigger(key, summary, example)
      Trigger.new(key: key, summary: summary, example: example)
    end

    def self.task(key, label)
      Task.new(key: key, label: label)
    end

    ALL = [
      Feature.new(
        key:        :push,
        title:      "Push notifications",
        permission: true,
        options:    [
          option(:push_badges, :boolean, "Unread count"),
          option(:native_push_replaces_web_push, :boolean, "Turn off web push"),
          option(:open_links_in_app, :boolean, "Open links in the app"),
          option(:push_channels, :channels, "Notify for", choices: PUSH_CHANNELS),
        ],
        tests:      [:alert, :badge, :silent],
      ),
      Feature.new(
        key:      :actionable_notifications,
        title:    "Notification buttons",
        triggers: [trigger(:ios_notification_action, "A button was pressed", "ios_notification_action:action::yes")],
      ),
      Feature.new(
        key:     :live_activities,
        title:   "Live Activities",
        options: [
          option(:live_activities_for_timers, :boolean, "Timers"),
          option(:live_activities_for_alarms, :boolean, "Alarms"),
          option(:live_activities_push_to_start, :boolean, "Start when the app is closed"),
        ],
        tests:   [:live_activity],
      ),
      Feature.new(
        key:        :alarms,
        title:      "Alarms",
        permission: true,
        options:    [
          option(:alarms_ring_alarms, :boolean, "Alarms"),
          option(:alarms_ring_timers, :boolean, "Timers"),
        ],
      ),
      Feature.new(
        key:      :hot_links,
        title:    "Hot links",
        triggers: [trigger(:ios_hot_link, "A trigger hot link was pressed", "ios_hot_link:name::Garage")],
      ),
      Feature.new(
        key:   :widgets,
        title: "Widgets",
        tasks: [task(:refresh_widgets, "Refresh")],
        tests: [:widgets],
      ),
      Feature.new(
        key:      :quick_commands,
        title:    "Offline queue",
        options:  [option(:commands_show_confirmations, :boolean, "Confirm each press")],
        triggers: [
          trigger(:tell, "A queued command", "tell:/log water/"),
          trigger(:ios_command, "Any command from the app", "ios_command:source::widget"),
        ],
      ),
      Feature.new(
        key:      :battery,
        title:    "Battery",
        options:  [option(:battery_writes_dashboard, :boolean, "Dashboard battery")],
        triggers: [trigger(:ios_battery, "Level or charging changed", "ios_battery:device::phone charging:true")],
        tasks:    [task(:send_battery, "Send now")],
      ),
      Feature.new(
        key:        :bluetooth_battery,
        title:      "Bluetooth batteries",
        permission: true,
        triggers:   [trigger(:ios_battery, "An accessory's level changed", "ios_battery:name:AirPods")],
      ),
      Feature.new(
        key:        :location,
        title:      "Location",
        permission: true,
        options:    [
          option(:location_mode, :select, "Updates", choices: LOCATION_MODES),
          option(:location_visits, :boolean, "Visits"),
          option(:location_regions, :boolean, "Saved places"),
          option(:location_feeds_travel, :boolean, "Travel"),
          option(:location_minimum_meters, :number, "Minimum move (m)", minimum: 25, maximum: 2000, step: 25),
        ],
        triggers:   [
          trigger(:ios_location, "A new position", "ios_location:kind::move"),
          trigger(:ios_location, "Arrived or left", "ios_location:kind::visit action::arrived"),
          trigger(:ios_location, "A saved place", "ios_location:kind::region action::departed place::Home"),
          trigger(:trytravel, "Arrivals and departures", "travel:action::arrived"),
        ],
      ),
      Feature.new(
        key:        :health,
        title:      "Workouts",
        permission: true,
        options:    [
          option(:health_logs_workout_event, :boolean, "Log as a Workout event"),
          option(:health_daily_totals, :boolean, "Daily totals"),
        ],
        triggers:   [
          trigger(:ios_workout, "A workout was saved", "ios_workout:type::running"),
          trigger(:event, "Logged as a Workout event", "event:name::Workout"),
          trigger(:ios_health, "Daily totals", "ios_health:kind::daily"),
        ],
        tasks:      [task(:check_workouts, "Check now")],
      ),
      Feature.new(
        key:        :calendar,
        title:      "Calendar",
        permission: true,
        options:    [
          option(:calendar_days_back, :number, "Days back", minimum: 0, maximum: 60, step: 1),
          option(:calendar_days_ahead, :number, "Days ahead", minimum: 1, maximum: 365, step: 1),
          option(:calendar_identifiers, :sources, "Calendars", source: :calendars),
        ],
        triggers:   [trigger(:ios_calendar, "An event changed", "ios_calendar:action::added")],
        tasks:      [task(:sync_calendar, "Sync"), task(:resend_calendar, "Resend all")],
      ),
      Feature.new(
        key:        :reminders,
        title:      "Reminders",
        permission: true,
        options:    [
          option(:reminders_include_completed, :boolean, "Include completed"),
          option(:reminder_list_identifiers, :sources, "Lists", source: :reminder_lists),
        ],
        triggers:   [
          trigger(:ios_reminders, "A reminder changed", "ios_reminders:action::completed list::Groceries"),
        ],
        tasks:      [task(:sync_reminders, "Sync")],
      ),
      Feature.new(
        key:        :contacts,
        title:      "Contacts",
        permission: true,
        triggers:   [trigger(:ios_contacts, "A contact changed", "ios_contacts:action::updated")],
        tasks:      [task(:sync_contacts, "Sync"), task(:resend_contacts, "Resend all")],
      ),
      Feature.new(
        key:      :share,
        title:    "Share sheet",
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

    def self.find(key)
      ALL.find { |feature| feature.key == key.to_s.to_sym }
    end
  end
end
