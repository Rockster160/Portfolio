module Buddy
  # Everything a Today briefing is about, gathered and decided in one place so
  # the companion's entire job is to say it well.
  #
  # Rocco, 2026-09-04: "Having a service that collects and provides all of the
  # data points and then just passing it to the buddy to talk about and phrase
  # in their own words and not have to use any tools is a complete refactor."
  #
  # What that replaced: a two-thousand-word prompt that described where to look,
  # what to filter, what to drop and what not to say, plus five pre-send repairs
  # that stapled the facts back on when it didn't. On 4 Sep all three briefings -
  # three people, three companions - ended with the same two sentences byte for
  # byte, because `with_weather` and `with_week_weather` had written them all
  # three times under the one paragraph the model actually wrote.
  #
  # So the deciding happens here, in Ruby, where it is testable and the same
  # every day. The prompt that carries this says how to SOUND, and nothing else.
  #
  # Read through Buddy::GPT::ContextTool on purpose. It owns the briefing
  # filters - passed items, routine reminders, another day's reminders, a
  # partner's uninvolved items, the daily chore rotation - and rebuilding any of
  # them here would mean two answers to "what's on today" that could drift.
  module BriefingFacts
    module_function

    # Rocco, 2026-09-04: "we also want to make sure that we are collecting all of
    # the information that Buddy previously was collecting. Reminders, memories,
    # and anything else that Buddy normally would have looked at and collected,
    # we should be collecting, determining if it should be included or not, and
    # then providing it."
    #
    # A briefing turn can no longer look anything up, so an absence here is a
    # silent decision unless it's written down. Every section Buddy can reach
    # gets a line, and a spec fails if `ContextTool::SECTIONS` ever grows one
    # that doesn't. `nil` means it is in the briefing; a string is why it isn't.
    SECTION_DECISIONS = {
      today_notable:          nil,
      upcoming_notable:       nil,
      upcoming_reminders:     nil,
      chores_due_today:       nil,
      stashed_ideas:          nil,
      pending_relays:         nil,
      # The ordinary week rather than this day - the roster, the habits, the
      # calendar's standing repeats. Taken away rather than sorted, because
      # every attempt to describe the difference in words lost while both were
      # in front of the model (ContextTool::BRIEFING_WITHHELD).
      today_agenda:           "the standing repeats; today_notable is the exceptions",
      upcoming_agenda:        "the standing repeats; upcoming_notable is the exceptions",
      chores_pending_today:   "their daily rotation, which is the day they already know",
      chores_done_today:      "done is not the day ahead",
      chores_hot_picks:       "the multiplier rides on the due-today row instead",
      chores_scheduled_today: "folded into chores_due_today by cadence",
      chores_overdue_backlog: "a backlog is not a today; it would lead every briefing",
      chores_all:             "the roster, which is the thing a briefing must never read out",
      # Yesterday, or the app's own furniture. A briefing is the day ahead.
      recent_events:          "yesterday",
      recent_actions:         "yesterday",
      active_proposals:       "a tap waiting in the thread, not a thing happening at a time",
      pebble_balance:         "a number they can see, and not news",
      lists:                  "a place things live, not something that happens today",
      routines:               "things they can run, not things that are running",
      app_pages:              "navigation",
      feature_requests:       "a wishlist",
      # Machinery. A briefing that narrates Buddy's own scheduling is the
      # "I'm going to check up on you today" failure - the thing being announced
      # is Buddy, not the day.
      active_watches:         "Buddy's own watches; announcing one is announcing Buddy",
      running_timers:         "a countdown they set minutes ago and are watching",
      jil_triggers:           "automation plumbing",
      jil_functions:          "automation plumbing",
      device_states:          "the house, on demand",
      trigger_shapes:         "automation plumbing",
      record_links:           "automation plumbing",
      pending_prompts:        "a form waiting in the app, which the app already badges",
    }.freeze

    SECTIONS = SECTION_DECISIONS.select { |_key, why| why.nil? }.keys.freeze

    # Deliberately NOT collected, and it isn't a ContextTool section at all:
    # a memory carrying `check_in_at` is Buddy's own plan to ASK about
    # something later (Buddy::CheckIns). Rocco, 4 Sep: "Buddy should NOT bring
    # things up like 'Oh, I'm going to check up on you today' just because there
    # is a check up today." The check-in speaks for itself when it fires.
    #
    # Their durable memories are not collected here either, because they are
    # already in front of the model: Buddy::Personality#memories_block puts
    # everything they ever asked to be remembered into every prompt, briefing
    # turns included. Fetching them twice would only make them a list to recite.

    # Alpine is a canyon Rocco drives to. For everyone else in the house it's a
    # town half an hour away whose forecast they have no reason to hear, and
    # their own weather is already in the block above it.
    def alpine?(user)
      user.present? && user.me?
    end

    def build(user, conversation, now: Time.current)
      served = context_for(user, conversation)

      {
        name:    user&.first_name,
        today:   Array(served[:today_notable]).reject { |i| i[:passed] },
        due:     Array(served[:upcoming_reminders]).select { |r| r[:status].blank? },
        jobs:    Array(served[:chores_due_today]),
        week:    Array(served[:upcoming_notable]),
        stash:   Array(served[:stashed_ideas]),
        waiting: Array(served[:pending_relays]),
        weather: weather(user, now),
        alpine:  (alpine?(user) ? alpine_lines(user, now) : {}),
      }
    end

    def context_for(user, conversation)
      return {} if user.nil? || conversation.nil?

      Buddy::GPT::ContextTool.new(user, conversation, briefing: true).filtered(SECTIONS)
    rescue StandardError => e
      Rails.logger.warn("[Buddy::BriefingFacts] context failed: #{e.class}: #{e.message}")
      {}
    end

    # Past mid-afternoon the day's high stops being something anyone can act on,
    # so it goes and the week's outlook stays - what's coming still matters.
    def weather(user, now)
      late = late_in_day?(user, now)
      out  = { week: WeatherService.week_outlook(user: user) }
      out.merge!(WeatherService.today_figures(user: user).to_h.slice(:high, :low, :notable)) unless late
      out.compact
    rescue StandardError => e
      Rails.logger.warn("[Buddy::BriefingFacts] weather failed: #{e.class}: #{e.message}")
      {}
    end

    def late_in_day?(user, now)
      return false if user.nil?

      hour = Buddy::Day.now(user, at: now).hour
      hour >= 16 || hour < Buddy::Day::ROLLOVER_HOUR
    end

    # Rocco, 2026-09-04: "We don't want Alpine included every day - only the days
    # with precipitation during the desired hours, otherwise it gets
    # ignored/dropped from the data and the prompt entirely."
    #
    # Both halves already answer with nothing on a dry day (PlungeAdvisor is
    # only ever about whether the canyon is wet), so this collapses to an empty
    # hash rather than a hash of empty lists - the key is gone from the facts,
    # the heading is gone from the seed, and the writing rule with it.
    def alpine_lines(user, now)
      today = Buddy::PlungeAdvisor.briefing_lines(user, now: now)
      week  = Buddy::PlungeAdvisor.week_rain_lines(user, now: now)
      return {} if today.compact_blank.empty? && week.compact_blank.empty?

      { today: today, week: week }
    rescue StandardError => e
      Rails.logger.warn("[Buddy::BriefingFacts] alpine failed: #{e.class}: #{e.message}")
      {}
    end

    # ---- rendering ---------------------------------------------------------
    #
    # One line per thing, in the order of the day. A time leads because that's
    # the shape a day has, and the departure rides on the item it belongs to
    # rather than arriving as its own paragraph at the end - which is exactly
    # what the leave-time repair was doing when it fired.

    def block(facts)
      sections = [
        ["ON TODAY",        facts[:today].map { |i| agenda_line(i, facts[:name]) }],
        ["ALSO DUE TODAY",  facts[:due].map { |r| "#{r[:fire_at]} · #{r[:body]}" }],
        ["JOBS TODAY",      job_lines(facts[:jobs])],
        ["WEATHER",         weather_lines(facts[:weather])],
        ["ALPINE",          Array(facts.dig(:alpine, :today)) + Array(facts.dig(:alpine, :week))],
        ["LATER THIS WEEK", facts[:week].map { |i| week_line(i) }],
        ["WAITING ON THEM", Array(facts[:waiting]).map { |r| "#{r[:from]} asked: #{r[:question]}" }],
        ["ON THEIR MIND",   facts[:stash].map { |idea| idea[:summary].presence || idea[:body] }],
      ].reject { |_title, lines| lines.compact_blank.empty? }
      return "" if sections.empty?

      sections.map { |title, lines|
        "#{title}\n#{lines.compact_blank.map { |line| "- #{line}" }.join("\n")}"
      }.join("\n\n")
    end

    # Whose it is leads the title, because that is the order somebody says it in
    # and it is the difference between "you have yoga at 4" and "Chelsea has
    # yoga at 4". Rocco, 4 Sep: the first is "absolutely incorrect".
    def agenda_line(item, name)
      title = item[:title]
      title = "#{item[:owner]}: #{title}" if item[:mine] == false && item[:owner].present?

      bits = [item[:time], title]
      bits << item[:where] if item[:where].present?
      bits << item[:cal] if item[:cal].present? && item[:cal] != name
      bits << "cancelled" if item[:cancelled]
      bits << "all day" if item[:all_day]
      line = bits.compact_blank.join(" · ")
      return line if item[:leave_by].blank?

      drive = item[:drive_min].to_i
      "#{line} · leave by #{item[:leave_by]}#{" (#{drive} min drive)" if drive.positive?}"
    end

    # Chores that came in under one name are one job. Five bin rows on a
    # Wednesday spelled out one by one is what buried the day they belong to;
    # `group` is worked out in Buddy::Context#tag_groups.
    def job_lines(rows)
      grouped, singles = Array(rows).partition { |row| row[:group].present? }
      lines = grouped.group_by { |row| row[:group] }.map { |group, members|
        "#{group}: #{members.pluck(:name).join(", ")}"
      }
      lines + singles.map { |row| [row[:name], row[:hot]].compact_blank.join(" · ") }
    end

    def weather_lines(weather)
      return [] if weather.blank?

      [
        ("High #{weather[:high]}°F, low #{weather[:low]}°F" if weather[:high].present?),
        weather[:notable].presence,
        ("This week: #{weather[:week]}" if weather[:week].present?),
      ]
    end

    def week_line(item)
      bits = [item[:day], item[:time], item[:title]]
      bits << item[:where] if item[:where].present?
      bits << "cancelled" if item[:cancelled]
      bits.compact_blank.join(" · ")
    end
  end
end
