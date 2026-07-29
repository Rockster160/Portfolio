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
        # Anchor to WHEN THE PERSON ASKED, not when the Mac round-trip finished, so
        # a slow turn doesn't quietly shave time off a "3 minute" timer.
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
    def anchor_time(conversation)
      return Time.current if conversation.nil?

      sent = conversation.byte_messages.where(direction: :outbound).order(:created_at).last&.created_at
      return Time.current if sent.nil? || sent > Time.current || sent < 1.hour.ago

      sent
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
