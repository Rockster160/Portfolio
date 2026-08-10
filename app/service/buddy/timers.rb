module Buddy
  # Buddy's countdown timers. Thin wrapper over the app's existing Timer stack
  # (server-authoritative firing via Sidekiq, push on expiry, MonitorChannel
  # broadcasts) so Buddy timers are precise across close/reopen/force-quit for
  # free. The ONLY Buddy-specific piece is isolation: every Buddy timer lives on
  # a hidden per-user "Buddy" TimerPage, so the hero shows only these and they
  # never clutter the person's regular timer board.
  module Timers
    module_function

    PAGE_SLUG = "buddy".freeze
    PAGE_NAME = "Buddy".freeze
    MAX_SECONDS = 24 * 60 * 60

    # ---- the fast path -------------------------------------------------------
    #
    # "5m" and "5m pasta" are unambiguous enough to serve from Rails without
    # waking the model. Going through a turn costs several seconds, which is
    # invisible on a 20-minute timer and most of the countdown on a 10-second
    # one, and it's several seconds during which the model may decide not to call
    # the tool at all. The agent keeps its own set_timer for everything shaped
    # less plainly than this.

    UNIT_SECONDS = {
      3600 => %w[h hr hrs hour hours],
      60   => %w[m min mins minute minutes],
      1    => %w[s sec secs second seconds],
    }.flat_map { |secs, names| names.map { |name| [name, secs] } }.to_h.freeze

    # Longest unit first so "minutes" wins over "min", and a not-a-letter
    # lookahead rather than \b: there is no word boundary between the "h" and the
    # "3" of "1h30m", so \b refused to match a compound duration at all.
    CHUNK_RX = /\A(\d{1,4})\s*(#{Regexp.union(UNIT_SECONDS.keys.sort_by { |u| -u.length })})(?![a-z])/i
    # "timer for 5m", "set a timer 90s" — saying the word makes it explicit, so
    # the label is trusted without further sniffing.
    LEAD_RX  = /\A(?:(?:set|start)\s+)?(?:an?\s+)?timer\s+(?:for\s+)?/i
    TRAIL_RX = /\s+timer\z/i

    # Words that mean the person is REPORTING a duration rather than asking for
    # one. "20 minutes of stretching" and "5 min walk done" both lead with a
    # duration and are chore completions; turning either into a countdown would
    # swallow a log the person cares about. Only consulted when they didn't say
    # "timer" outright.
    REPORT_RX = /\b(?:of|done|did|finished|ago|already|left|remaining|so far|total)\b/i

    # Words that mean they're ASKING the companion for something, which is a
    # sentence rather than a label. "2 hours early please Suki" parsed as a
    # two-hour countdown named "early please Suki" - it cleared every check
    # because the leftover happened to be exactly three words. Nobody names a
    # timer this way; a real one is "5m pasta". Same gate as REPORT_RX: only
    # consulted when they didn't say "timer" outright.
    ASK_RX = /\b(?:please|remind|remember|nudge|wake|tell|let me know)\b/i

    # Buddy having just asked something. Not only "?" - Suki's persona makes her
    # terminate almost everything in "!", so a question from her frequently
    # carries no question mark at all. A sentence OPENING with an interrogative
    # is the half that survives that.
    QUESTION_RX = /\?|(?:\A|[.!?]\s+)(?:how|what|when|which|who|where|why|do you|are you|would you|want|should i|shall i)\b/i

    # Inbound kinds that are Buddy talking, as opposed to a receipt chip or a
    # card. Mirrors Buddy::GPT::History::PROSE_KINDS.
    PROSE_KINDS = %w[buddy buddy_reply].freeze

    # Above this, a leading duration is far likelier to be narration ("8 hours
    # sleep") than a countdown request, so it goes to the model instead.
    FAST_PATH_MAX_SECONDS = 3 * 60 * 60
    FAST_PATH_MAX_LENGTH  = 60
    FAST_PATH_MAX_LABEL_WORDS = 3

    # Returns { seconds:, label: } when the message is plainly a timer request,
    # otherwise nil so the caller falls through to a normal Buddy turn.
    #
    # `conversation` is what the message is landing in, and it's optional only
    # because the parse is also exercised on bare strings. Pass it: without it
    # this reads a message with no idea what it's replying to, which is how
    # "2 hours early please Suki" - an answer to "how early do you want the
    # nudge?" - became a countdown and left the question unanswered.
    def parse_request(body, conversation: nil)
      text = body.to_s.strip
      return nil if text.empty? || text.length > FAST_PATH_MAX_LENGTH || text.include?("?")

      explicit = false
      if text.sub!(LEAD_RX, "")
        explicit = true
      end
      explicit = true if text.sub!(TRAIL_RX, "")

      seconds = 0
      while (match = text.match(CHUNK_RX))
        seconds += match[1].to_i * UNIT_SECONDS.fetch(match[2].downcase)
        text = match.post_match.strip
      end
      return nil if seconds < 1 || seconds > FAST_PATH_MAX_SECONDS

      # A "timer" sitting between the duration and the label is the word for the
      # THING, not a name for it: "10m timer for pasta" is a pasta timer, and
      # calling it "timer for pasta" would be daft. The "for" and the article
      # that usually trail it go the same way, so "5m timer for the pasta" comes
      # out as plain "pasta" rather than blowing the label-length check.
      explicit = true if text.sub!(/\Atimer\b/i, "")
      label = text.strip.sub(/\Afor\b/i, "").strip.sub(/\A(?:the|an?)\b/i, "").strip

      return nil if label.split.length > FAST_PATH_MAX_LABEL_WORDS
      # A bare "5m walk done" reads as a report; "5m timer walk" does not.
      return nil if !explicit && label.present? && label.match?(REPORT_RX)
      return nil if !explicit && label.present? && label.match?(ASK_RX)
      # An answer to a question Buddy just asked is a reply, not a request, and
      # the fast path answers nothing - it posts a chip and returns, so the
      # question is left hanging and they have to say it twice. Saying "timer"
      # outright still wins, since that's unambiguous whatever came before it.
      return nil if !explicit && replying_to_a_question?(conversation)

      # Politeness, not a name. Only reachable on an explicit request ("timer
      # for 5m please"), since ASK_RX has already turned everything else away.
      label = label.sub(/\Aplease\b/i, "").sub(/\bplease\z/i, "").strip

      { seconds: seconds, label: label.presence }
    end

    # Did Buddy's last turn end on a question? Reads the newest message in the
    # thread, which at intake is still Buddy's reply - the person's message is
    # posted only once the fast path has declined it.
    def replying_to_a_question?(conversation)
      return false if conversation.nil?

      last = conversation.byte_messages.order(:created_at).last
      return false if last.nil? || last.direction != "inbound"

      meta = last.metadata.is_a?(Hash) ? last.metadata : {}
      return false unless PROSE_KINDS.include?(meta["kind"].to_s)

      last.body.to_s.match?(QUESTION_RX)
    rescue StandardError
      false
    end

    # Create the timer AND post the same activity chip the tool path posts, so a
    # fast-path timer is indistinguishable from one the model set. Returns the
    # chip, or nil if the timer couldn't be started.
    def quick_set!(user, conversation, seconds:, label: nil)
      timer = create!(user: user, seconds: seconds, label: label, conversation: conversation)
      name  = conversation.buddy_name
      text  = "#{name} set a #{humanize_seconds(seconds)} timer#{" for #{label}" if label.present?} ⏲"

      chip = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         text,
        metadata:     {
          "kind"      => "buddy_activity",
          "tool_name" => "set_timer",
          "ok"        => true,
          "source"    => "fast_path",
          "payload"   => { "seconds" => seconds, "label" => label.to_s },
          "timer_id"  => timer.id,
        },
        delivered_at: Time.current,
      )
      broadcast_chip(user, chip)
      chip
    rescue StandardError => e
      Buddy::Errors.report(section: "timers.quick_set", exception: e, user: user)
      nil
    end

    def page_for(user)
      user.timer_pages.find_or_create_by!(slug: PAGE_SLUG) do |page|
        page.name = PAGE_NAME
        page.meta = { "buddy" => true }
      end
    end

    # Create + start a countdown. Broadcasts :created so the hero picks it up
    # live (the model only broadcasts on fire/confirm/chain on its own).
    def create!(user:, seconds:, label: nil, conversation: nil, metadata: {})
      secs  = seconds.to_i.clamp(1, MAX_SECONDS)
      clean = label.to_s.strip.first(60)
      page  = page_for(user)
      timer = nil

      # Create + start ATOMICALLY. Timer#start! schedules the Sidekiq fire inside
      # its own transaction, so if the job backend is unreachable the start rolls
      # back — and this outer transaction rolls back the row with it. Without this
      # a failed start leaves a dead countdown (no end_at, no scheduled fire) that
      # renders a chip which never ticks OR fires; better to fail loudly so the
      # tool reports "couldn't set that" than to show a zombie.
      ActiveRecord::Base.transaction do
        timer = user.timers.create!(
          kind:        :countdown,
          duration_ms: secs * 1000,
          name:        clean,
          timer_page:  page,
          metadata:    metadata.to_h,
        )
        # Anchor to WHEN THE PERSON ASKED, not when the turn finished, so a slow
        # turn doesn't quietly shave time off a "3 minute" timer.
        timer.start!(at: anchor_time(conversation))
        raise ActiveRecord::Rollback unless timer.running?
      end

      raise "timer failed to start (fire scheduling unavailable?)" unless timer&.persisted? && timer.running?

      timer.broadcast(reason: :created)
      timer
    end

    # Buddy timers the hero should actually SHOW on hydrate: only ones that are
    # counting, paused, or ringing (fired-but-unacknowledged). Deliberately
    # excludes confirmed / reset / never-started rows — `live` (archived_at nil)
    # alone would resurrect every finished timer on each refresh, since
    # confirm!/reset! don't archive. A started countdown keeps started_at set
    # through firing; confirm! clears it, so "started_at OR paused_at present"
    # is exactly the still-relevant set.
    def live_for(user)
      page = user.timer_pages.find_by(slug: PAGE_SLUG)
      return Timer.none if page.nil?

      user.timers.live
        .where(timer_page_id: page.id, kind: :countdown)
        .where("started_at IS NOT NULL OR paused_at IS NOT NULL")
        .ordered
    end

    # Stop a countdown for good: kill the scheduled fire and the mid-countdown
    # callbacks, archive the row, and broadcast so the chip drops off every open
    # surface. Same three steps as a swipe-away in Buddy::TimersController, kept
    # here so the `cancel_timer` tool and the gesture can't drift apart.
    def stop!(timer)
      timer.cancel_fire!
      timer.cancel_countdown_callbacks!
      timer.update!(archived_at: Time.current)
      timer.broadcast(reason: :archived)
      timer
    end

    # Is this timer one of Buddy's? Used to gate broadcast handling on the
    # client and to scope controller actions to Buddy's own timers.
    def buddy_timer?(user, timer)
      page = user.timer_pages.find_by(slug: PAGE_SLUG)
      page.present? && timer.timer_page_id == page.id
    end

    # Called by TimerFireWorker right after a countdown fires. For Buddy's own
    # timers, Buddy speaks up in the conversation (and the same delivery pushes,
    # covering the away case). No-op + self-contained error handling for anything
    # that isn't a Buddy timer, so the generic worker can call it unconditionally.
    def on_fired(timer)
      return unless timer&.countdown? && buddy_timer?(timer.user, timer)

      conversation = Buddy::CompanionRelay.conversation_for(timer.user)
      return if conversation.nil?

      # An ALARM is a moment arriving, not time running out — the countdown is
      # only how the noise gets made (see Buddy::Alarms). It says the thing it
      # was set for; announcing the mechanism is what "your Washer's done
      # timer's done" was.
      alarm = Buddy::Alarms.alarm?(timer)

      # A WAIT is Buddy holding the middle of a sequence the person asked for
      # ("start the printer, wait a minute, then preheat it"), not a countdown
      # they're watching. Say what's happening rather than that time is up — the
      # step it was holding lands directly underneath.
      label   = timer.name.to_s.strip
      waiting = !alarm && Buddy::ProposalBuilder.waiting_on?(timer)
      Buddy::CompanionDelivery.deliver_plain(
        user:         timer.user,
        conversation: conversation,
        text:         alarm ? Buddy::Alarms.fired_text(timer) : fired_text(label, waiting: waiting),
        metadata:     { "kind" => "buddy", "source" => alarm ? "alarm" : "timer", "timer_id" => timer.id },
        push_title:   alarm ? Buddy::Alarms.fired_title(timer) : fired_title(label, waiting: waiting),
      )
      Buddy::ProposalBuilder.resume_after!(timer) if waiting
    rescue StandardError => e
      Buddy::Errors.report(section: "timers.on_fired", exception: e, user: timer&.user)
    end

    def fired_text(label, waiting:)
      named = (" on #{label}" if label.present?)
      return "⏲ That's the wait#{named} - picking it back up." if waiting
      return "⏲ Time's up - your #{label} timer's done!" if label.present?

      "⏲ Time's up - your timer's done!"
    end

    def fired_title(label, waiting:)
      return "Picking it back up" if waiting

      label.present? ? "#{label} timer" : "Timer's up"
    end

    # The moment the countdown should count FROM: the most recent message the
    # person sent in this thread (the timer request itself). Clamped to a recent
    # window and never the future, so a queued/replayed turn can't anchor the
    # timer hours in the past. Falls back to now when there's nothing to anchor.
    #
    # Deliberately NOT capped as a fraction of the duration. A "5 minute timer"
    # should end five minutes after you asked, full stop — trimming the back-date
    # to protect short countdowns just makes every timer end at a slightly
    # different offset than the one requested. A short timer arriving with a
    # second left is correct; the fix for it feeling instant is not spending
    # seconds in a model round trip (see ByteController's timer fast path).
    def anchor_time(conversation)
      return Time.current if conversation.nil?

      sent = conversation.byte_messages.where(direction: :outbound).order(:created_at).last&.created_at
      return Time.current if sent.nil? || sent > Time.current || sent < 1.hour.ago

      sent
    end

    def broadcast_chip(user, message)
      MonitorChannel.broadcast_to(user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: message.as_wire },
      })
    end

    # "5 min", "90 sec", "1 min 30 sec" - for receipts.
    def humanize_seconds(seconds)
      secs = seconds.to_i
      mins, rem = secs.divmod(60)
      return "#{secs} sec" if mins.zero?
      return "#{mins} min" if rem.zero?

      "#{mins} min #{rem} sec"
    end
  end
end
