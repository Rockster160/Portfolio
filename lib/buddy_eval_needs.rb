# What a probe's `needs:` names, and how to tell whether it is actually there.
#
# This used to be a sentence, and a miss on a probe carrying one was filed as
# "not answerable from this person's data" without anybody checking. That guess
# was harmless while the preconditions really were absent. The moment
# BuddyEvalWorld started BUILDING them it became wrong in the expensive
# direction: the 21 Aug run reported ten missing preconditions - the recycling
# chore, the tomato reminder, the greenhouse idea, the Whisper Sound function -
# that were all sitting in the database while it said so. Ten real failures,
# filed under "nothing to see here".
#
# So a `needs:` is a KEY now, and the key knows how to look. A miss is only
# excused when the thing genuinely isn't there.
#
# `check: nil` means live state that can't be read from the database - the
# printer answering, a proposal in the thread to undo. Those stay unanswerable,
# and the report says which ones and why, rather than implying somebody could
# go and seed them.
require Rails.root.join("lib/buddy_eval_world")

module BuddyEvalNeeds
  module_function

  def label(key)
    TABLE.dig(key, :label) || key.to_s.tr("_", " ")
  end

  def known?(key)
    TABLE.key?(key)
  end

  def keys
    TABLE.keys
  end

  # Three answers, not two: true, false, and nil for "nothing here can tell".
  # Deliberately not `met?` — a predicate that returns nil is a predicate
  # somebody will treat as false, and the difference between "the printer isn't
  # answering" and "we have no way to ask the printer from a database" is the
  # difference between a bug to fix and a probe to leave alone.
  def met(key, user)
    check = TABLE.dig(key, :check)
    return nil if check.nil?

    check.call(user)
  rescue StandardError => e
    warn "[eval needs] #{key} couldn't be checked: #{e.class}: #{e.message}"
    nil
  end

  def chore(user, rx)
    household = user.chore_household
    return false if household.nil?

    Chore.where(chore_household: household).active.any? { |c| c.name.to_s.match?(rx) }
  end

  # How many, for probes that count rather than ask whether.
  def completions(user, rx)
    ChoreCompletion.where(user: user, day_key: user.perceived_today).includes(:chore).count { |c|
      c.chore&.name.to_s.match?(rx)
    }
  end

  def completion(user, rx)
    ChoreCompletion.where(user: user, day_key: user.perceived_today).includes(:chore).any? { |c|
      c.chore&.name.to_s.match?(rx)
    }
  end

  # Scoped to the eval thread, because that's the only place a reminder is
  # VISIBLE: Buddy::Context#upcoming_reminders reads the conversation it's
  # speaking in. One of theirs in another thread satisfies nothing — the turn
  # can't see it, and answering "I don't see a tomato reminder" is then correct.
  def reminder(user, rx=nil)
    convo = user.byte_conversations.evals.find_by(name: BuddyEvalWorld::EVAL_THREAD)
    return false if convo.nil?

    scope = BuddyReminder.pending.where(user: user, byte_conversation_id: convo.id)
    rx.nil? ? scope.exists? : scope.any? { |r| r.body.to_s.match?(rx) }
  end

  def event_today(user, rx)
    user.action_events.where(timestamp: user.perceived_today.beginning_of_day..).any? { |e|
      e.name.to_s.match?(rx)
    }
  end

  def list_item(user, rx)
    ListItem.where(list_id: user.lists.reload.map(&:id)).any? { |i| i.name.to_s.match?(rx) }
  end

  def stash(user, rx)
    user.buddy_memories.kind_stash.status_active.any? { |m| m.content.to_s.match?(rx) }
  end

  # A Jil task Buddy is actually SHOWN. One of theirs that isn't buddy_enabled
  # is invisible to the model, which is the same as absent for a probe's
  # purposes and a different problem from a description that can't be found.
  def jil(user, rx, kind: :function)
    Task.where(user: user, buddy_enabled: true, enabled: true).any? { |task|
      next false unless task.name.to_s.match?(rx) || task.listener.to_s.match?(rx)

      kind == :function ? task.listener.to_s.start_with?("function") : !task.listener.to_s.start_with?("function")
    }
  end

  def delivery?(user, name)
    Buddy::Deliveries.available?(user) && Buddy::Deliveries.find(user, name).present?
  end

  TABLE = {
    recycling_chore:      { label: "a recycling chore",            check: ->(u) { chore(u, /recycl/i) } },
    water_chore:          { label: "a water chore",                check: ->(u) { chore(u, /water/i) } },
    water_completion:     { label: "a water completion today",     check: ->(u) { completion(u, /water/i) } },
    recycling_completion: { label: "a recycling completion today", check: ->(u) { completion(u, /recycl/i) } },
    pending_reminder:     { label: "a pending reminder in the eval thread", check: ->(u) { reminder(u) } },
    tomato_reminder:      { label: "a tomato reminder in the eval thread", check: ->(u) { reminder(u, /tomato/i) } },
    flower_bed_reminder:  { label: "a flower bed reminder in the eval thread", check: ->(u) { reminder(u, /flower bed/i) } },
    vet_reminder:         { label: "a vet reminder in the eval thread", check: ->(u) { reminder(u, /vet/i) } },
    celsius_today:        { label: "a Celsius logged today",       check: ->(u) { event_today(u, /celsius/i) } },
    sandwich_today:       { label: "a sandwich logged today",      check: ->(u) { event_today(u, /sandwich/i) } },
    oat_milk_listed:      { label: "oat milk on a list",           check: ->(u) { list_item(u, /oat milk/i) } },
    greenhouse_idea:      { label: "a stashed greenhouse idea",    check: ->(u) { stash(u, /greenhouse/i) } },
    wind_down_routine:    { label: "a wind-down routine",          check: ->(u) { BuddyRoutine.where(user: u).any? { |r| r.name.to_s.match?(/wind.?down/i) } } },
    bakkie_defined:       { label: "bakkie in the glossary",       check: ->(u) { u.chore_household && HouseholdGlossaryTerm.where(chore_household: u.chore_household).any? { |t| t.term.to_s.casecmp?("bakkie") } } },
    dentist_on_calendar:  { label: "a dentist item on the calendar", check: ->(u) { AgendaItem.where(agenda_id: u.agendas.map(&:id), start_at: Time.current..1.month.from_now).any? { |i| i.name.to_s.match?(/dentist/i) } } },
    coffee_pairing:       { label: "the coffee-to-chore pairing",  check: ->(u) { RecordLink.where(user: u).any? { |l| l.source_name.to_s.match?(/coffee/i) } } },
    desk_delivery:        { label: "a desk on the delivery list",  check: ->(u) { delivery?(u, "desk") } },
    mattress_delivery:    { label: "a mattress on the delivery list", check: ->(u) { delivery?(u, "mattress") } },
    pending_prompt:       { label: "a pending prompt",             check: ->(u) { u.prompts.unanswered.exists? } },
    whisper_sound_fn:     { label: "the Whisper Sound function",   check: ->(u) { jil(u, /whisper sound/i) } },
    camera_fn:            { label: "the Camera Last Seen function", check: ->(u) { jil(u, /camera/i) } },
    fan_fn:               { label: "a fan function",               check: ->(u) { jil(u, /fan/i) } },
    light_fn:             { label: "an office light function",     check: ->(u) { jil(u, /office light/i) } },
    jil_trigger:          { label: "a matching jil trigger",       check: ->(u) { jil(u, /chill/i, kind: :trigger) } },
    open_relay_question:  { label: "an open question from someone else", check: ->(u) { BuddyRelay.open_questions_for(u).exists? } },

    # Live state, not rows. Nothing to seed and nothing to check.
    printer_reachable:    { label: "the printer answering", check: nil },
    undoable_in_thread:   { label: "something undoable in this thread", check: nil },
  }.freeze
end
