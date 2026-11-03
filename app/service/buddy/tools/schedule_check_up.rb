# A few questions about how they are, asked on a schedule, with the answers
# kept. Each asking is a reminder carrying an `ask_check_up` call, so it fires
# on time with no model turn, shows in `upcoming_reminders`, and stops the way
# anything else on the clock does.
Buddy::Tools.register(
  name:        :schedule_check_up,
  summary:     "Check in on how they are, on a schedule, with a form of questions they rate or " \
               "answer: \"check on my headache and cough every day at 9am and 9pm\", \"check on " \
               "my mental state every night\".",
  description: <<~TXT,
    Ask them about themselves on a schedule: symptoms while they're ill, their
    mood or mental state, pain, sleep, their cycle. Each time it comes round
    the questions arrive in the thread as one form; what they answer is kept,
    and the next form opens on their last ratings so a symptom that hasn't
    changed is one tap.

    Every question is about them, and only they can answer it: answered with
    a rating, a pick, a yes/no or a few words. The record of those answers
    over time is the point.

    ## Arguments

      title     - what they asked you to check on, in their own words. The
                  same title later carries on the same history.
      questions - exactly the things they named, one per line, each in their
                  own words, and nothing they didn't name. A line is the
                  question, optionally followed by `|` and how it's answered:
                    <question>                     a 0-10 rating, the default
                    <question> | scale <low>-<high>
                    <question> | text
                    <question> | yes/no
                    <question> | date
                    <question> | pick: <choice>, <choice>, ...
                  A Notes box is always added at the end.
      repeat    - when it comes round: daily:HH:MM, weekdays:HH:MM,
                  weekly:<days>:HH:MM, monthly:<day of month>:HH:MM or
                  every:<n>-<unit>:HH:MM. Several times a day is one spec per
                  line.
      at        - one asking at a single time (ISO datetime), instead of
                  `repeat`.
      starts    - the first day (YYYY-MM-DD), when they named one.
      until     - stop repeating after this date (YYYY-MM-DD).

    With no time of day named, pick the one that suits the question.

    ## Changing one

    Call this again with its title, exactly as the reminder in
    `upcoming_reminders` shows it after "Check-up:", and only what changes:

      questions - a line for each question to change or add. A line replaces
                  the question of the same name; a new name is added. The
                  rest stay as they are.
      remove    - questions to stop asking, by name, one per line.
      repeat/at - new times, which replace the old ones. Left out, it keeps
                  its times.

    An asking they leave unanswered is asked again next time rather than
    piling up. Each time is a reminder in `upcoming_reminders`; stopping it is
    cancelling that, and one set for several times a day is one plan.
  TXT
  feature:     :prompts,
  args:        {
    title:     { type: :string, required: true,  description: "Short name for what's being checked, in their words" },
    questions: { type: :string, required: false, description: "Only the things they named, one per line, optionally `| scale <low>-<high>`, `| text`, `| yes/no`, `| date` or `| pick: <choice>, <choice>`" },
    repeat:    { type: :string, required: false, description: "Recurrence spec, one per line for several times a day: daily:HH:MM / weekdays:HH:MM / weekly:<days>:HH:MM / monthly:<dom>:HH:MM / every:<n>-<unit>:HH:MM" },
    at:        { type: :string, required: false, description: "A single asking (ISO datetime), instead of `repeat`" },
    starts:    { type: :string, required: false, description: "First day it can come round (YYYY-MM-DD), when not today" },
    until:     { type: :string, required: false, description: "Stop repeating after this date (YYYY-MM-DD)" },
    remove:    { type: :string, required: false, description: "Changing one: questions to stop asking, by name, one per line" },
  },
  auto:        true,
  level:       2,
  # A second call with the same title changes the first, which is never what a
  # replayed routine means.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    title = payload[:title].to_s.squish
    raise "a check-up needs a title" if title.empty?

    existing = Buddy::CheckUp.scheduled(ctx.user, title).to_a
    timed    = payload[:repeat].to_s.strip.present? || payload[:at].to_s.strip.present?
    if existing.empty? && !timed
      names = Buddy::CheckUp.titles(ctx.user)
      running = " (the ones running are #{names.to_sentence})" if names.any?
      raise "no check-up called #{title.inspect} to change#{running}; a new one needs a `repeat` or an `at`"
    end

    title = existing.first.metadata["check_up"] if existing.any?
    text  = (
      if existing.any?
        Buddy::CheckUp.revise(Buddy::CheckUp.questions_of(existing.first), payload[:questions], remove: payload[:remove])
      else
        Buddy::CheckUp.split(payload[:questions]).join("\n")
      end
    )
    questions = Buddy::CheckUp.questions(text)
    tz        = ctx.user.timezone
    today     = ctx.user.perceived_today

    starts = (Date.parse(payload[:starts].to_s) rescue nil) if payload[:starts].to_s.strip.present?
    raise "couldn't read #{payload[:starts].inspect} as a date" if payload[:starts].to_s.strip.present? && starts.nil?

    ends = (Date.parse(payload[:until].to_s) rescue nil) if payload[:until].to_s.strip.present?
    raise "couldn't read #{payload[:until].inspect} as a date" if payload[:until].to_s.strip.present? && ends.nil?

    specs = payload[:repeat].to_s.split(/[\n;]/).map(&:strip).compact_blank
    times = specs.map { |spec|
      recurrence = Buddy::RepeatSpec.parse(spec, on: [starts, today].compact.max)
      raise "unknown repeat spec #{spec.inspect}" if recurrence.nil?

      recurrence = recurrence.merge("until_on" => ends.iso8601) if ends
      # Not before the day they named, however the rule would otherwise land.
      from    = starts ? [Time.current, starts.in_time_zone(tz).beginning_of_day].max : Time.current
      fire_at = BuddyReminder.new(user: ctx.user, recurrence: recurrence).next_fire_at(from: from)
      raise "#{spec.inspect} never comes round" if fire_at.nil?

      { "fire_at_iso" => fire_at.iso8601, "recurrence" => recurrence }
    }

    if times.empty? && payload[:at].to_s.strip.present?
      fire_at = ctx.resolve_time(payload[:at])
      raise "couldn't work out when to ask" if fire_at.nil?
      raise "that time has already passed" if fire_at < Time.current

      times = [{ "fire_at_iso" => fire_at.iso8601 }]
    end

    asked   = questions.pluck(:question).to_sentence
    summary = (
      if times.empty?
        "Change **#{title}** to ask #{asked}?"
      else
        first = times.map { |time| Time.zone.parse(time["fire_at_iso"]) }.min
        "Check on **#{title}** (#{asked}), first #{Buddy::Clock.day_at(first, zone: tz)}?"
      end
    )

    {
      summary:  summary,
      resolved: {
        title:        title,
        questions:    text,
        # Left out when changing only the questions, so it keeps its times.
        times:        times.presence,
        reminder_ids: existing.map(&:id).presence,
      }.compact,
    }
  },
  label:       ->(payload, _ctx) {
    lines = Buddy::CheckUp.split(payload[:questions]).map { |line| line.split("|", 2).first.strip }
    { title: payload[:title].to_s, sub: [payload[:repeat], *lines].compact_blank.join("\n") }
  },
  execute:     ->(payload, ctx) {
    conversation = ByteConversation.for_self_initiated(ctx.user)
    raise "no conversation to ask in" if conversation.nil?

    title    = payload[:title].to_s
    call     = { "tool" => "ask_check_up", "payload" => { "title" => title, "questions" => payload[:questions] } }
    body     = Buddy::CheckUp.body(title, payload[:questions])
    existing = BuddyReminder.pending.where(user_id: ctx.user.id, id: Array(payload[:reminder_ids]))

    reminders = (
      if payload[:times].blank?
        existing.each { |reminder| reminder.update!(action: [call], body: body) }
      else
        # New times replace the old ones rather than joining them.
        existing.each { |reminder| reminder.update!(cancelled_at: Time.current) }
        Array(payload[:times]).map { |time|
          time = time.to_h.stringify_keys
          BuddyReminder.create!(
            user:              ctx.user,
            byte_conversation: conversation,
            kind:              :reminder,
            body:              body,
            fire_at:           Time.zone.parse(time["fire_at_iso"].to_s),
            recurrence:        time["recurrence"],
            action:            [call],
            plan_id:           Buddy::Plan.current_id,
            metadata:          { "check_up" => title },
          )
        }
      end
    ).to_a

    {
      reminder_ids: reminders.map(&:id),
      title:        title,
      changed:      existing.any?,
      questions:    Buddy::CheckUp.split(payload[:questions]).map { |line| line.split("|", 2).first.strip },
      fire_at:      reminders.filter_map(&:fire_at).min&.iso8601,
      recurrences:  reminders.filter_map(&:recurrence),
    }
  },
  receipt:     ->(result, ctx) {
    recurrences = Array(result[:recurrences])
    when_s = (
      if recurrences.any?
        recurrences.map { |rec| Buddy::ReminderPresenter.repeat_phrase(rec) }.to_sentence
      else
        ctx.friendly_future(Time.zone.parse(result[:fire_at].to_s))
      end
    )
    return "**#{result[:title]}** now asks #{Array(result[:questions]).to_sentence}, #{when_s}" if result[:changed]

    "#{ctx.buddy_name} will check on **#{result[:title]}** #{when_s}"
  },
)
