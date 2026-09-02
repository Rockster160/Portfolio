module Buddy
  # Deciding WHEN Buddy comes back to something on its own.
  #
  # ## No quota
  #
  # An early draft capped this at one open check-in per person. That was wrong
  # twice over. One person may have nothing worth following up while another
  # genuinely has a sick cat AND a parent with a broken leg, and neither should
  # cost the other its check-in. Worse, a floor with an empty slot in it is an
  # invitation to fill the slot: told it may schedule one, a model finds one,
  # and the thing it finds is whatever was nearest rather than whatever
  # mattered.
  #
  # What actually prevents this being annoying is that check-ins are placed
  # RELATIVE TO EACH OTHER. Everything pending gets re-placed together, spaced
  # so two never land in one sitting, inside hours a person is actually awake.
  # A new arrival takes the near slot and pushes the rest back; nothing is
  # dropped, it moves. Someone with nothing pending has nothing pending.
  #
  # ## Severity is not the running order
  #
  # A parent's surgery next week is severe the moment it's mentioned and worth
  # nothing until the week turns. `relevant_at` is what says a record is LIVE;
  # severity only breaks ties between records that are equally live. Ordering on
  # severity alone asks about next week's surgery tomorrow.
  module CheckIns
    module_function

    # Fixed bands rather than a profile derived per person. Simpler, and it
    # lands in the same places: 30 days of real message history shows this
    # household awake 07:00-01:00 and completely dark 04:00-06:00, so every band
    # here sits inside hours somebody is actually up.
    #
    # Each band is for a different kind of returning-to-something.
    BANDS = {
      # An hour or so after the Today summary. For things that are about TODAY.
      morning:   (9..10),
      # Lighter, lower-stakes check-ins.
      afternoon: (13..16),
      # The common one.
      evening:   (18..20),
      # Affirmations and emotional check-ins, when the day has wound down.
      night:     (22..23),
    }.freeze

    # Never two in one sitting, and never two in a day. The spacing is what
    # replaces a quota — it bounds how often a person hears from Buddy
    # unprompted without ever deciding that a real concern doesn't deserve one.
    MIN_GAP = 20.hours

    # A person mid-conversation does not need an interruption about something
    # from last week. Inside this window of their last message, a due check-in
    # moves rather than fires.
    BUSY_WINDOW = 1.hour

    # Move `at` onto the next band boundary at or after it, in the person's own
    # zone. Which band depends on how soon it is: something for later today
    # belongs in the evening, something a week out can take the common slot.
    def place(at, user:, now: Time.current)
      zone   = ActiveSupport::TimeZone[user.timezone.presence || "America/Denver"] || Time.zone
      target = at.in_time_zone(zone)
      band   = band_for(target, now.in_time_zone(zone))
      slide(target, band, zone)
    end

    # Which band suits something landing at `target`.
    def band_for(target, now)
      return BANDS[:evening] if target.to_date == now.to_date && now.hour < BANDS[:evening].last
      return BANDS[:night]   if target.to_date == now.to_date

      BANDS[:evening]
    end

    # First moment inside `band` at or after `target`, rolling to the next day
    # when the band has already passed.
    #
    # The result is guaranteed to be >= target. Bands land on the hour, so
    # keeping `target`'s own hour would move a 19:22 target back to 19:00 —
    # which is how a check-in ended up scheduled BEFORE the surgery it was
    # meant to follow.
    def slide(target, band, zone)
      day  = target.to_date
      hour = target.min.positive? || target.sec.positive? ? target.hour + 1 : target.hour
      if hour > band.last
        day += 1
        hour = band.first
      end
      hour = band.first if hour < band.first
      zone.local(day.year, day.month, day.day, hour, 0, 0)
    end

    # Re-place every pending check-in this person has, together.
    #
    # Called after a compile writes new follow-ups, which is the moment the set
    # has changed and the moment a new higher-severity concern should be able to
    # take the near slot. Ordering is relevance first (what is live now), then
    # severity, then how long it has been waiting.
    def replan!(user, now: Time.current)
      pending = BuddyMemory.where(user: user).check_in_pending(now).to_a
      pending += BuddyMemory.where(user: user).check_in_due(now).to_a
      pending = pending.uniq.select(&:check_in_plannable?)
      return [] if pending.empty?

      # Seeded from the LAST CHECK-IN only, never from the clock. MIN_GAP spaces
      # check-ins relative to EACH OTHER - "never two in one sitting, and never
      # two in a day" - and seeding with `now` turned it into a flat 20-hour
      # delay on the first one in the queue, whether or not there was anything
      # to be spaced from.
      #
      # Prod: Eve's dinner check-in (buddy_memories 128) was written 31 Aug at
      # 2:05 PM, four hours before the 6:00 PM dinner it was about, and asked
      # 1 Sep at 6:00 PM - the day after. Her previous check-in was 25 Aug, six
      # days earlier, and hers still moved. Both check-ins that have ever fired
      # landed after the thing they were about.
      #
      # `cursor = placed` at the end of the loop still spaces the rest, so the
      # second and later ones in one pass are unaffected.
      cursor = last_check_in_at(user)
      ordered(pending, now).each { |memory|
        earliest = [cursor && (cursor + MIN_GAP), memory.relevant_at, memory.check_in_at, now].compact.max
        placed   = place(earliest, user: user, now: now)
        memory.update_columns(check_in_at: placed, updated_at: Time.current)
        # Scheduled per-record. A record whose time moved gets a second job; the
        # worker re-reads the column, so the earlier one finds a time that has
        # drifted and reschedules rather than firing early.
        BuddyCheckInWorker.perform_at(placed, memory.id)
        cursor = placed
      }
    end

    # Live first, then weight, then age. `relevant_at` in the future means not
    # live yet, and a severity-90 record that isn't live sits behind a
    # severity-40 one that is.
    def ordered(pending, now)
      pending.sort_by { |m|
        [
          m.relevant_at.present? && m.relevant_at > now ? 1 : 0,
          -m.severity,
          m.created_at.to_i,
        ]
      }
    end

    def last_check_in_at(user)
      BuddyMemory.where(user: user).where.not(checked_in_at: nil).maximum(:checked_in_at)
    end

    # Everything due to be asked about right now, most important first. Empty
    # while the person is mid-conversation — see `fire!`.
    def due(user, now: Time.current)
      ordered(BuddyMemory.where(user: user).check_in_due(now).select { |m| m.check_in_candidate?(now) }, now)
    end

    # When did this person last say something? Used to hold a check-in back
    # rather than interrupt a live conversation with it.
    #
    # `outbound` alone is not "the person": every seeded turn is written as an
    # outbound message too — a briefing, a watch firing, a reminder, and check-in
    # delivery itself all go through CompanionDelivery#deliver_prompt. Counting
    # those meant Buddy talking to ITSELF read as the person being mid-
    # conversation, so the 8:30 briefing would push any check-in due in the hour
    # after it, every single day, and a check-in would defer the next one behind
    # it. Hence the same silent kinds every other reader here skips.
    def last_spoke_at(user)
      ByteMessage.joins(:byte_conversation)
        .where(byte_conversations: { user_id: user.id, mode: ByteConversation.modes[:buddy] })
        .where(direction: ByteMessage.directions[:outbound])
        .where("COALESCE(byte_messages.metadata ->> 'hidden', '') <> 'true'")
        .where(
          "COALESCE(byte_messages.metadata ->> 'kind', '') NOT IN (?)",
          ByteMessage::SILENT_KINDS,
        )
        .maximum(:created_at)
    end

    # Ask about one.
    #
    # Two gates, both of which RECOMPUTE rather than skip — a check-in that
    # silently evaporates is the thing the person would most want to have
    # happened:
    #
    #   1. Mid-conversation. They're right here; a scheduled question about last
    #      week reads as an interruption. Push to an hour past their last
    #      message. (`outbound` is the PERSON's message and `inbound` is
    #      Buddy's — implementing this off the enum names alone inverts it.)
    #   2. No longer worth asking. Resolved, dropped, or severity fallen away
    #      since it was armed — then it closes rather than fires.
    #
    # Returns :fired, :deferred, or :closed.
    def fire!(memory, now: Time.current)
      user = memory.user
      return close!(memory) unless memory.check_in_candidate?(now)

      spoke = last_spoke_at(user)
      if spoke && spoke > now - BUSY_WINDOW
        moved = place(spoke + BUSY_WINDOW, user: user, now: now)
        memory.update_columns(check_in_at: moved, updated_at: Time.current)
        BuddyCheckInWorker.perform_at(moved, memory.id)
        return :deferred
      end

      deliver!(memory, user, now)
      :fired
    rescue StandardError => e
      Buddy::Errors.report(
        section: "check_ins.fire", exception: e, user: memory.user, extra: { memory_id: memory.id },
      )
      :closed
    end

    def close!(memory)
      memory.update_columns(check_in_at: nil, updated_at: Time.current)
      :closed
    end

    # Seeds a turn rather than posting a fixed line, so the question is composed
    # now, in this thread's voice, with the record and everything since it in
    # view. `checked_in_at` is stamped here and is a LAST-CHECKED mark, not a
    # seal: an answer can re-arm `check_in_at` and ask again another day. What
    # never happens is a second unprompted ask about a check-in they ignored.
    def deliver!(memory, user, now)
      conversation = Buddy::CompanionRelay.conversation_for(user)
      memory.update_columns(check_in_at: nil, checked_in_at: now, updated_at: Time.current)

      Buddy::CompanionDelivery.deliver_prompt(
        user:         user,
        conversation: conversation,
        seed:         seed(memory, now),
        metadata:     {
          kind: "buddy_trigger", hidden: true, source: "check_in", memory_id: memory.id
        },
      )
    end

    def seed(memory, now)
      thread = memory.notes.any? ? "\n\nWhat you've got on it:\n#{memory.transcript(now)}" : ""
      <<~TXT
        Something you noted #{memory.waiting_label(now)} to come back to:

        #{memory.content}#{thread}

        Check in on it, in your own words, the way a friend would who had been thinking about them. One thing, asked once. Don't announce that you scheduled this, don't explain that you kept a note, and don't stack it with anything else you could be asking about.

        If it reads as heavy, be gentle and leave them room to say nothing. If it's a lighter one, keep it light. If you no longer have anything useful to ask - it plainly resolved itself in the conversation since - say nothing at all rather than manufacturing a question.
      TXT
    end
  end
end
