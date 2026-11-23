require_relative "../script/app_store/config"

module AppStore
  # Buddy's half of the release scripts (ios/script/app_store): who it is, where its
  # project lives, and the words its store listing and App Review start from.
  BUDDY = Config.new(
    name:              "Buddy",
    bundle_id:         "com.ardesian.buddy",
    dir:               __dir__,
    sku:               "buddy-ios",
    xcconfigs:         ["Config/Shared.xcconfig", "Config/Local.xcconfig"],
    new_app_name:      "Buddy by Ardesian",
    first_note:        <<~TEXT.tr("\n", " ").strip,
      First build: log in, allow push on the device's page, add a hot link, put a
      list or panel widget on the home screen, and say "Tell Buddy" to Siri.
    TEXT
    site:              "https://ardesian.com",
    support_url:       "https://ardesian.com/support",
    description:       <<~TEXT.tr("\n", " ").strip,
      Buddy is the iPhone app for your ardesian.com account: talk to Buddy, run your
      automations, keep lists, agenda and timers on the Home and Lock Screen, and keep your
      account in step with your phone's battery, location, workouts, calendars and contacts,
      each only when you switch it on.
    TEXT
    keywords:          "assistant,automation,widgets,timers,lists,agenda,shortcuts,home",
    categories:        [
      ["Productivity", "PRODUCTIVITY"],
      ["Utilities", "UTILITIES"],
      ["Lifestyle", "LIFESTYLE"],
    ],
    review_notes:      <<~TEXT.tr("\n", " ").strip,
      Buddy is the iPhone app for an ardesian.com account: lists, an agenda, timers, chores,
      automations, and a conversation with Buddy. Accounts are made on the website
      (ardesian.com/register); the app only signs in to one. Beyond the
      site, the app adds native push with answer buttons, timers as Live Activities and
      AlarmKit alarms, widgets, Siri and Shortcuts, Home Screen quick actions, and the share
      sheet. Every device integration that needs a permission (location, HealthKit workouts,
      calendar, reminders, contacts, Bluetooth) is off until allowed in the app, which is when
      iOS asks, and sends only to the person's own account; nothing is used for tracking.
      The demo account holds sample data only.
    TEXT
    age_rating_steps:  [
      "Under Age Rating, click Set Up Age Rating (or Edit).",
      <<~TEXT.chomp,
        Answer None or No to each question: Buddy has no mature content, gambling, chat
        between strangers or open web browsing (its web view only shows the person's own
        account on ardesian.com).
      TEXT
      "Click Done, then Save at the top right.",
    ],
    app_privacy_steps: [
      "Under Data Collection, click Get Started (or Edit): yes, the app collects data.",
      <<~TEXT.chomp,
        Tick Location: Precise Location; Health and Fitness: Health, Fitness; Contacts:
        Contacts; User Content: Photos or Videos, Other User Content (messages to Buddy);
        Identifiers: User ID; Other Data: Other Data Types (calendar events, reminders,
        battery levels). Click Save.
      TEXT
      <<~TEXT.chomp,
        For each one: used for App Functionality, linked to the person's identity, not used
        for tracking.
      TEXT
      "Click Publish at the top right.",
    ],
    audience:          <<~TEXT.chomp,
      people with an ardesian.com account that Buddy has been opened to, who install it
      from the link on their account's devices page
    TEXT
  )
end
