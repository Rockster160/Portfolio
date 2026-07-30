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

    # Above this, a leading duration is far likelier to be narration ("8 hours
    # sleep") than a countdown request, so it goes to the model instead.
    FAST_PATH_MAX_SECONDS = 3 * 60 * 60
    FAST_PATH_MAX_LENGTH  = 60
    FAST_PATH_MAX_LABEL_WORDS = 3

    # Returns { seconds:, label: } when the message is plainly a timer request,
    # otherwise nil so the caller falls through to a normal Buddy turn.
    def parse_request(body)
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

      { seconds: seconds, label: label.presence }
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
    def create!(user:, seconds:, label: nil, conversation: nil)
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

      label = timer.name.to_s.strip
      text  = label.present? ? "⏲ Time's up - your #{label} timer's done!" : "⏲ Time's up - your timer's done!"
      Buddy::CompanionDelivery.deliver_plain(
        user:         timer.user,
        conversation: conversation,
        text:         text,
        metadata:     { "kind" => "buddy", "source" => "timer", "timer_id" => timer.id },
        push_title:   label.present? ? "#{label} timer" : "Timer's up",
      )
    rescue StandardError => e
      Buddy::Errors.report(section: "timers.on_fired", exception: e, user: timer&.user)
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
