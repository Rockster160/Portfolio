module Buddy
  # Notes queued to ride along on somebody's next Today briefing.
  #
  # The point is that they are NOT read out verbatim. A line pasted into an
  # otherwise-written briefing is audible — it arrives in a different voice than
  # everything around it, and the briefing stops sounding like the companion
  # halfway through. So what reaches the model is the substance plus an
  # instruction to say it in its own words, the same way every other fact in
  # that prompt is handed over.
  #
  # ## Why they're claimed when the seed is built
  #
  # `Buddy::TodayBriefing.seed` is called exactly once per briefing, from both
  # paths that produce one (the scheduled reminder via `deliver!`, and the hero
  # chip via Buddy::QuickActionsController). That makes it the one place a
  # claim can happen without either double-delivering or needing a second hook
  # on a path that doesn't have one.
  #
  # The tradeoff is real and deliberate: if the turn then fails, the
  # announcement is stamped delivered without anyone having heard it. That's why
  # `delivered_at` is a stamp rather than a delete — a delivered row stays
  # visible at /system/announcements and re-queues in one click, which is a
  # smaller problem than an announcement that goes out twice.
  module Announcements
    module_function

    # Enough for a couple of real notes without a briefing turning into a
    # noticeboard. Anything past this waits for the next one.
    MAX_PER_BRIEFING = 3

    # Queue one. `expires_in` keeps a time-bound note from surfacing days later,
    # which is the failure mode a queue like this has by default: nothing else in
    # the system would ever clear "the plumber comes this afternoon".
    def queue!(user:, body:, expires_in: nil)
      text = body.to_s.strip
      return nil if text.empty?

      BuddyAnnouncement.create!(
        user:       user,
        body:       text.first(BuddyAnnouncement::MAX_BODY),
        expires_at: expires_in.presence && (Time.current + expires_in),
      )
    end

    def pending_for(user, now: Time.current)
      BuddyAnnouncement.where(user: user).pending(now).limit(MAX_PER_BRIEFING).to_a
    end

    # The block that rides in the briefing seed, and the claim, together —
    # because a caller that built the block and forgot to claim would repeat the
    # same announcement every morning forever.
    #
    # Returns "" when there's nothing queued, so a briefing for someone with no
    # announcements is byte-identical to what it was before this existed.
    def claim_block!(user, now: Time.current)
      rows = pending_for(user, now: now)
      return "" if rows.empty?

      BuddyAnnouncement.where(id: rows.map(&:id)).update_all(delivered_at: now, updated_at: now)
      block(rows)
    end

    def block(rows)
      lines = rows.map { |row| "- #{row.body.strip}" }.join("\n")
      <<~TXT

        ANNOUNCEMENTS — say these, in your own words:
        #{lines}

        These are things I've asked you to pass on, and they belong in this briefing rather than a message of their own. Work each one in where it fits the day you're describing; if one relates to something already on the agenda, say them together rather than twice.

        Say the substance, not the sentence. The wording above is mine and it is a note TO you, not a line to read out - a phrase lifted straight from it lands in a different voice from the rest of the briefing, which is the one way to make this obvious. Keep every fact, especially names, times and numbers, and change everything else.

        **Most of these will be about YOU** - something you can newly do, something changing in how you work, something to keep an eye on. Those are yours to say in the first person, as a thing about you rather than a release note: what it means for them, what to try, what might look different. "I can look back through our old conversations now, so just ask if you can't place when we talked about something" - never "conversation search has been added". Don't call it an update, a feature, a version, a rollout or a change log.

        If something might go wrong or look odd, say so plainly and warmly. Being told what to watch for is the entire reason it's worth mentioning, and a change described as seamless is how somebody ends up believing they broke it.

        Don't announce that it's an announcement, don't say you were asked to mention it, and don't set it apart with a heading or a preamble. It's part of the briefing like anything else in it.
      TXT
    end
  end
end
