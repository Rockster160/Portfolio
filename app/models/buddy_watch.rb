# == Schema Information
#
# Table name: buddy_watches
#
#  id                   :bigint           not null, primary key
#  body                 :text             not null
#  cancelled_at         :datetime
#  expires_at           :datetime
#  fired_at             :datetime
#  kind                 :string           default("prompt"), not null
#  last_fired_at        :datetime
#  listener             :string
#  match                :jsonb            not null
#  metadata             :jsonb            not null
#  one_shot             :boolean          default(TRUE), not null
#  trigger_scope        :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#  notify_user_id       :bigint
#  user_id              :bigint           not null
#
class BuddyWatch < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation
  # When present, the watch delivers to this person's companion instead of the
  # owner's ("whenever I add to our Agenda, let them know"). Same household.
  belongs_to :notify_user, class_name: "User", optional: true

  # `prompt` seeds a Buddy turn, `reminder` delivers a fixed line, and `action`
  # runs a Jil automation with no model in the loop at all. That last one exists
  # because "trigger whisper-quiet ten seconds after the doggy door" is not a
  # nudge - nobody is being told anything - and routing it through a turn would
  # put a language model between a sensor and a light at 2am.
  #
  # `timer` starts a countdown. A message in the thread is something you have to
  # be LOOKING at; a timer going off is a noise in the room, and "a 1 second
  # timer every time something lands in the Claude list" is asking for the
  # second one. Buddy answered that ask with a reminder watch, was told "No. I
  # said set a TIMER", and replied that a timer only runs from now - true of
  # `set_timer`, and the reason this exists.
  #
  # `alarm` rings AT the condition rather than counting down from it. It exists
  # because a one-second `timer` watch was how that got expressed, and the
  # result read as one: the receipt said "Byte will start a 1 second timer", the
  # reminders list said "starts a 1 sec timer", and the thing that went off
  # announced itself as a timer finishing. What the person asked for was an
  # alarm for when the washer is done, and every surface named the mechanism
  # instead of the thing.
  KINDS = %w[reminder prompt action timer alarm cancel].freeze

  # How long a delayed action may hold. Long enough for "a couple of minutes
  # after", short enough that a queue backed up behind one is a bug rather than
  # a design. Anything longer is a reminder or a schedule, not a reflex.
  MAX_ACTION_DELAY = 15.minutes.to_i

  def action?
    kind.to_s == "action"
  end

  def timer?
    kind.to_s == "timer"
  end

  def alarm?
    kind.to_s == "alarm"
  end

  # A watch whose whole job is to switch a REMINDER off when something happens.
  #
  # "Check the printer every 30 minutes until the print finishes" is two rules,
  # and only the first of them was expressible: a repeat has a clock-time end
  # (`until_at`) and a date end (`until_on`) and no way to say "until that
  # thing". The `check` conditions are a different question — they decide
  # whether ONE firing speaks, so a print that finished leaves a reminder alive
  # and re-asking every half hour tomorrow.
  #
  # The condition machinery for "when X happens" already existed and is the
  # same one `remind_when` uses; the only thing missing was something for it to
  # switch off.
  def cancels?
    kind.to_s == "cancel"
  end

  def cancels_reminder_id = metadata.to_h["cancels_reminder_id"].presence&.to_i

  # A work/break CYCLE, by the id it carries through every block. Not the timer
  # row: the block running when this fires is the fifth one in the chain, and
  # the one that was running when the watch was armed is long archived.
  def cancels_cycle_id = metadata.to_h["cancels_cycle"].presence

  # The Jil scope this watch fires, the task name it was resolved from (for the
  # receipt and the reminders list), and how long to wait first.
  def run_scope      = metadata.to_h["run_scope"].to_s.presence
  def run_task_name  = metadata.to_h["run_task_name"].to_s.presence
  def run_delay      = metadata.to_h["run_delay"].to_i.clamp(0, MAX_ACTION_DELAY)

  # A function call with its arguments, run instead of a bare scope. Same
  # shape as a reminder's `action`, and run the same way.
  def run_calls
    row = metadata.to_h["run_call"]
    return [] unless row.is_a?(Hash) && row["tool"].present? && Buddy::Tools[row["tool"]]

    [{ tool_name: row["tool"].to_sym, payload: (row["payload"] || {}).transform_keys(&:to_sym) }]
  end

  # How long the countdown runs each time this trips.
  def timer_seconds  = metadata.to_h["timer_seconds"].to_i

  # The scopes the NAMED triggers use (arrive/depart, chore, event, deploy,
  # agenda). A custom listener isn't limited to these: it names whatever scope
  # its syntax says, and `Jil::Executor.trigger` only ever fires a scope in the
  # context of the user whose data it is, so there's nothing here to guard.
  NAMED_SCOPES = %w[travel chore_completion event deploy agenda_item].freeze

  # `active` = not terminally fired, not cancelled, not expired. One-shot
  # watches set `fired_at` after firing (terminal); repeating watches only
  # set `last_fired_at` and stay active until cancelled/expired.
  scope :active, ->(now = Time.current) {
    where(fired_at: nil, cancelled_at: nil)
      .where("expires_at IS NULL OR expires_at > ?", now)
  }

  validates :body,          presence: true, length: { maximum: 500 }
  validates :kind,          inclusion: { in: KINDS }
  validates :trigger_scope, presence: true
  validates :listener,      presence: true
  validate  :listener_parses

  # WatchMatcher bails on any scope nothing is watching, off a cached set. A new
  # watch on a scope nobody was watching has to invalidate that set or it won't
  # fire until the TTL rolls over.
  after_commit :bust_watch_scope_cache

  # Has a condition at all. A row from before every watch carried a listener
  # has none, and can't be edited as one.
  def custom?
    listener.present?
  end

  # Every watch is a Jil listener, matched by the same code a Jil task is -
  # nested keys, regex, exclusions, `near()` - so a named trigger and a
  # hand-written one can't disagree about what fired.
  def matches?(payload)
    return false if listener.blank?

    ::Jil::ListenerMatch.call(listener, trigger_scope, payload)
  end

  private

  def bust_watch_scope_cache
    ::Buddy::WatchMatcher.bust_scope_cache!
  rescue StandardError => e
    Rails.logger.warn("[BuddyWatch] scope cache bust failed: #{e.class}: #{e.message}")
  end

  # A listener that can't be parsed would sit there matching nothing, which is
  # the one failure a reminder must not have: they'd believe it was set.
  def listener_parses
    return if listener.blank?

    # Named first: a listener can be well-formed, name a real scope and real
    # fields, and still be dead on a notation slip. "isn't a listener that would
    # ever fire" is true of that and tells whoever wrote it nothing.
    if (fault = ::Jil::ListenerMatch.fault(listener))
      return errors.add(:listener, fault)
    end
    return if ::Jil::ListenerMatch.valid?(listener, user: user) && ::Jil::ListenerMatch.scope_of(listener) == trigger_scope

    errors.add(:listener, "isn't a listener that would ever fire")
  end
end
