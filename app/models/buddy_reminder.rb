# == Schema Information
#
# Table name: buddy_reminders
#
#  id                   :bigint           not null, primary key
#  action               :jsonb
#  body                 :text             not null
#  cancelled_at         :datetime
#  condition            :jsonb
#  fire_at              :datetime         not null
#  fired_at             :datetime
#  kind                 :string           default("reminder"), not null
#  last_fired_at        :datetime
#  metadata             :jsonb            not null
#  recurrence           :jsonb
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#  notify_user_id       :bigint
#  user_id              :bigint           not null
#
class BuddyReminder < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation
  # Who it's FOR, when that isn't the person who set it. The row stays owned by
  # the requester so it's theirs to see and cancel; ReminderFirer routes the
  # delivery. Mirrors BuddyWatch#notify_user exactly.
  belongs_to :notify_user, class_name: "User", optional: true

  KINDS = %w[reminder prompt].freeze

  # `pending` = neither fired-terminally nor cancelled. Recurring
  # reminders never set `fired_at` - they set `last_fired_at` and roll
  # `fire_at` forward to the next occurrence, so they stay in `pending`
  # forever until cancelled.
  scope :pending, -> { where(fired_at: nil, cancelled_at: nil) }
  scope :due,     ->(now = Time.current) { pending.where("fire_at <= ?", now) }
  scope :upcoming, ->(now = Time.current, limit_hours = 48) {
    pending.where("fire_at > ?", now).where("fire_at < ?", now + limit_hours.hours).order(:fire_at)
  }

  validates :body,    presence: true, length: { maximum: 500 }
  validates :fire_at, presence: true
  validates :kind,    inclusion: { in: KINDS }

  def recurring?
    normalized_recurrence["freq"].present?
  end

  # "run the wind-down routine", "trigger printer preheat", "fire whisper quiet".
  #
  # Deliberately narrow: an explicit run-verb, then a name. A reminder is
  # usually an instruction to the PERSON ("take the trash out"), and those are
  # imperative too, so anything looser would start firing automations off
  # ordinary nudges. The trailing noun is optional and stripped, since people
  # write "run the X routine" as often as "run X".
  COMMAND_RX = /
    \A\s*
    (?:run|re-?run|trigger|fire|start|launch|execute)\s+
    (?:the\s+|my\s+)?
    (?<name>.+?)
    (?:\s+(?:routine|task|automation|again))?
    \s*[.!]*\s*\z
  /xi

  # A tool call to make when this comes due, as a ProposalBuilder marker, or nil
  # for an ordinary reminder.
  #
  # Distinct from `command` below, which reads a NAME back out of the body text
  # and re-resolves it at fire time. That covers "run my wind-down" and can't
  # cover anything with arguments — there is nowhere in a sentence to put
  # `sound: "nap"` — which is why "Play Whisper Nap sound at 11" had no way to be
  # scheduled at all and got played immediately instead (prod 3562).
  #
  # The tool NAME is stored, never a resolved id, so this degrades the same way
  # a routine step does: the function is looked up again every time it fires.
  def action_call
    row = action
    return nil unless row.is_a?(Hash)

    tool = row["tool"].presence
    return nil if tool.blank? || Buddy::Tools[tool].nil?

    { tool_name: tool.to_sym, payload: (row["payload"] || {}).transform_keys(&:to_sym) }
  end

  # Is this reminder a note to them, or something to actually DO?
  #
  # Answered when it FIRES rather than when it's set, which is the whole point:
  # `kind` was fixed at creation, invisible afterwards, and frequently wrong.
  # Resolving at fire time also means it degrades honestly - rename the routine
  # and the reminder goes back to being a line of text instead of quietly
  # running the wrong thing.
  #
  # Returns the thing to run, or nil for an ordinary reminder.
  def command
    match = COMMAND_RX.match(body.to_s)
    return nil if match.nil?

    name = match[:name].to_s.strip
    return nil if name.length < 2

    routine = Buddy::Routines.find(user, name)
    return { kind: :routine, routine: routine, name: routine.name } if routine

    task = Buddy::ToolContext.new(user).resolve_jil_trigger(name)
    return nil if task.nil? || !task[:plain]

    { kind: :jil, scope: task[:scope], name: task[:name] }
  rescue StandardError
    nil
  end

  # A pending reminder that already means THIS, at this minute, or nil.
  #
  # Asking again about something you already asked about is the normal shape of
  # a conversation, and Buddy has no memory of having set one three hours ago -
  # `upcoming_reminders` is available and simply wasn't read. Prod: "please
  # alert me of both of those items" produced second copies of two reminders
  # set that morning, and both fired twice, at 3:15 and again at 3:35.
  #
  # Same MINUTE and a shared word, both required. Same minute alone would
  # collapse "check the oven" and "call mom" at six o'clock into one, and
  # losing a real reminder is a worse failure than the double ping this exists
  # to stop.
  #
  # RECURRING ones count, and used to be excluded on the reasoning that "a
  # daily 9am and a one-off tomorrow at 9am are genuinely different requests".
  # They are - and the minute window already says so, because a recurring
  # reminder's `fire_at` is its NEXT fire, so a daily 9am only lands in the
  # window on the day it's about to go off. Excluding them threw away the one
  # case where it matters. Prod: reminder 37 was the daily noon plant check
  # and reminder 40 was set for the same noon, both fired, and 37's recurrence
  # was the only thing that hid it (msgs 3448/3449).
  # There used to be a `cancelled_like` here, and a receipt that said "(back on,
  # you'd switched this off Aug 19)" whenever it matched. It's gone.
  #
  # It matched on ONE shared significant word across sixty days, which is not a
  # narrowing — `clashing` below uses the same one-word test but only after
  # pinning to a single minute, which is what makes that one safe. So Eve asking
  # for a 9pm nudge about a YouTube video on propagating snake plants was told
  # she'd switched it off, on the strength of "plant" appearing in a noon plant
  # check she cancelled the day before (prod 4115).
  #
  # It isn't worth fixing the threshold, because there's nothing on the other
  # side of it. A cancelled row is kept so an undo has something to restore, and
  # that's the whole job. Telling somebody what they turned off a fortnight ago,
  # while they are in the middle of asking for something else, is a fact about
  # our bookkeeping wearing the clothes of a thing a friend would remember.
  def self.clashing(user, text, fire_at)
    words = significant_words(text)
    return nil if words.empty? || fire_at.blank?

    minute = fire_at.change(sec: 0)
    scope  = pending.where(user_id: user.id)
    scope  = scope.where(fire_at: minute...(minute + 1.minute))
    scope.find { |r| significant_words(r.body).intersect?(words) }
  end

  # Words worth matching on: everything that isn't scaffolding. Deliberately a
  # small list rather than a real stemmer - the comparison only has to separate
  # "outfit" from "meatloaf", and it's already narrowed to one minute.
  FILLER = <<~WORDS.split.to_set.freeze
    about after alert and are before check do done for get got going make made
    my need needs please put remind reminder take that the then this you your
  WORDS

  # The one bit of stemming there is, because plural-vs-singular is how the
  # same subject usually turns up twice: "water all the PLANTS" and "do the
  # PLANT check" shared no word at all, so the noon duplicate walked straight
  # through. Four characters before anything comes off, so "gas" stays "gas"
  # while "bins" and "cars" reach their singulars. Both sides fold the same
  # way, so the only risk is two different words landing on one stem - and a
  # clash is raised with the existing reminder quoted in it, so a wrong one is
  # something the model can answer rather than something that vanishes.
  def self.significant_words(text)
    text.to_s.downcase.scan(/[a-z]+/).filter_map { |w|
      next nil if w.length < 3 || FILLER.include?(w)

      w.length >= 4 ? w.delete_suffix("s") : w
    }.to_set
  end

  # The repeat pattern, as the shared matcher the calendar uses.
  #
  # A reminder used to carry four frequencies of its own with no interval, no
  # nth-weekday and no end date, so "every second Tuesday" was something the
  # calendar could express and a reminder could not - for no reason other than
  # which file the code was in. It now speaks the same rule vocabulary; see
  # Recurrence for the shapes.
  #
  # `at` (the wall-clock time of day) and `starts_on` (what an interval counts
  # from) ride in the same hash, since a reminder has no columns for them.
  def rule
    data = normalized_recurrence
    Recurrence.new(
      data,
      starts_on: parse_date(data["starts_on"]) || created_at&.to_date || Time.current.to_date,
      until_on:  parse_date(data["until_on"]),
    )
  end

  def time_of_day
    hh, mm = (normalized_recurrence["at"].presence || "09:00").to_s.split(":").map(&:to_i)
    [hh.to_i.clamp(0, 23), mm.to_i.clamp(0, 59)]
  end

  # Older rows wrote `{kind:, weekday:, day:}` before reminders and the calendar
  # shared a vocabulary. Translated on read rather than only in a migration, so
  # a row written by the previous release keeps firing through the deploy.
  LEGACY_WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

  def normalized_recurrence
    data = (recurrence || {}).with_indifferent_access
    return data if data["kind"].blank?

    converted = { "freq" => data["kind"].to_s, "at" => data["at"] }
    if data["weekday"].present?
      index = LEGACY_WEEKDAYS.index(data["weekday"].to_s.downcase)
      converted["by_day"] = [Recurrence::WEEKDAY_KEYS[index].to_s] if index
    end
    converted["by_month_day"] = [data["day"].to_i] if data["day"].present?
    converted.merge(data.slice("starts_on", "until_on", "excluded_dates", "until_at", "every_minutes")).compact
  end

  # The next moment this should go off, or nil when the pattern has run out
  # (an end date that's passed) so the firer can mark it terminal.
  #
  # Two layers, and keeping them apart is the whole design. `Recurrence` decides
  # WHICH DAYS and knows nothing about clocks — it's shared with the calendar and
  # has a JS port with a parity spec, so a sub-daily frequency there would mean
  # reworking the calendar's engine to answer a question reminders alone were
  # asking. The intraday window below decides WHICH TIMES within each of those
  # days, and lives here where it's needed. "Hourly from 9 to 11pm on weekdays"
  # is one of each, composed.
  def next_fire_at(from: Time.current)
    return nil unless recurring?

    tz    = ActiveSupport::TimeZone[user&.timezone.to_s] || Time.zone
    local = from.in_time_zone(tz)
    pattern = rule

    # Today counts only if its hour hasn't already gone by, so a daily 9am
    # asked at 9:01 rolls to tomorrow rather than firing immediately.
    date = pattern.next_on_or_after(local.to_date)
    while date
      slot = slots_on(date, tz).find { |candidate| candidate > local }
      return slot if slot

      date = pattern.next_on_or_after(date + 1)
    end
    nil
  end

  # Every moment this fires on one of its days: just `at` normally, and `at`
  # stepped by `every_minutes` up to `until_at` when a window is set.
  #
  # Bounded by MAX_INTRADAY_SLOTS rather than trusted to terminate: a zero or
  # negative step is a rule that never advances, and this runs inside the
  # minute-by-minute sweep.
  MAX_INTRADAY_SLOTS = 96

  def slots_on(date, tz)
    hh, mm = time_of_day
    first  = tz.local(date.year, date.month, date.day, hh, mm)
    step   = every_minutes
    ends   = window_end_on(date, tz)
    return [first] if step.nil? || ends.nil? || ends <= first

    slots = []
    at    = first
    while at <= ends && slots.length < MAX_INTRADAY_SLOTS
      slots << at
      at += step.minutes
    end
    slots
  end

  # Minutes between fires within a day, or nil for the ordinary once-a-day
  # reminder. Floored at 1 so a rule can't ask to fire every zero minutes.
  def every_minutes
    raw = normalized_recurrence["every_minutes"]
    return nil if raw.blank?

    [raw.to_i, 1].max
  end

  def window_end_on(date, tz)
    raw = normalized_recurrence["until_at"]
    return nil if raw.blank?

    hh, mm = raw.to_s.split(":").map(&:to_i)
    tz.local(date.year, date.month, date.day, hh.to_i.clamp(0, 23), mm.to_i.clamp(0, 59))
  end

  # Does this repeat WITHIN a day as well as across days?
  def intraday?
    recurring? && every_minutes.present? && normalized_recurrence["until_at"].present?
  end

  # The check answered when this comes due, or nil. See ScheduleCondition.
  def condition_data
    ScheduleCondition.normalize(condition)
  end

  def conditional?
    ScheduleCondition.present?(condition)
  end

  private

  def parse_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
