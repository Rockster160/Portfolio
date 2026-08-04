module Buddy
  # Snapshot injected into the system prompt each turn so Buddy can reference
  # today's agenda, recent events, chore state, etc. Kept intentionally small
  # (target < 1.5 KB) — this ships with every turn.
  module Context
    module_function

    RECENT_EVENT_WINDOW = 24.hours
    # Rest-of-week lookahead (past today). 8 days so "exactly a week from now"
    # still lands in the window.
    UPCOMING_WEEK_WINDOW = 8.days

    # Sections belonging to a feature this person doesn't have are dropped
    # rather than returned empty — an empty `chores_pending_today` reads as "you
    # have nothing due today", which is a different (and wrong) statement from
    # "chores aren't part of your setup".
    def build(user, conversation)
      full(user, conversation).except(*Buddy::Features.hidden_sections(user))
    end

    def full(user, conversation)
      tz = user.timezone
      now = Time.current.in_time_zone(tz)
      today = user.perceived_today

      chore_buckets = build_chore_buckets(user, today)

      {
        now_local:              now.strftime("%a %Y-%m-%d %-I:%M %p %Z"),
        timezone:               tz,
        user_first_name:        user.first_name,
        emotional_state:        emotional_state(conversation, now),  # current mood + pet expression
        today_agenda:           today_agenda(user, now),
        upcoming_agenda:        upcoming_agenda(user, now),          # rest-of-week, unusual-first
        # Two explicit lists per bucket - PENDING and DONE_TODAY - so
        # Buddy can never confuse "what's left" with "what's finished".
        # The previous mixed-list-with-done_today-flag was getting
        # glossed over (LLM reads the list, ignores the flag).
        chores_pending_today:   chore_buckets[:pending_today],
        chores_done_today:      chore_buckets[:done_today],
        chores_hot_picks:       chore_buckets[:hot_picks],       # attention items
        chores_scheduled_today: chore_buckets[:scheduled_today], # recurring chores landing today but NOT in the user's intentional list
        chores_overdue_backlog: chore_buckets[:overdue_backlog], # long-term todo, NOT all-must-do-today
        chores_all:             chore_buckets[:all_names],       # EVERY active chore name - the match roster for complete_chore
        pebble_balance:         user.chore_balance,              # spendable pebbles, for "how many do I have" and withdraw_pebbles
        recent_events:          recent_events(user, now),
        lists:                  lists(user),                    # the person's lists + each one's sections, for filing items in the right place
        active_proposals:       active_proposals(conversation),
        upcoming_reminders:     upcoming_reminders(conversation, now),
        running_timers:         running_timers(user),                # countdowns on the clock right now, for "how long left" and cancel_timer
        active_watches:         active_watches(conversation),
        conversation_notes:     conversation.buddy_memories,         # this thread's own notes ("keep this strictly work")
        pending_relays:         pending_relays(user),                # open questions from a partner, awaiting THIS user's answer
        pending_prompts:        pending_prompts(user),               # app surveys/questions Buddy can answer or skip on demand
        stashed_ideas:          stashed_ideas(user),                 # brain-dump ideas to occasionally resurface
        jil_triggers:           jil_triggers(user),
        jil_functions:          jil_functions(user),
        routines:               routines(user),                      # saved sequences one phrase runs end to end
      }
    end

    # Publicly-callable helper. Both this module (for emotional_state)
    # and Buddy::QuickActionsController (for the check-in prompt) call
    # it - keep them in sync by owning the map in one place.
    def mood_vibe_for(mood)
      case mood.to_s
      when "great" then "energized, in a solid headspace, up-and-forward."
      when "good"  then "steady, no complaints and no big highs."
      when "okay"  then "middling, neither up nor down."
      when "low"   then "worn down, tired in a way sleep may not fix."
      when "rough" then "genuinely having a hard time. Heavy."
      else              "somewhere in the middle."
      end
    end

    class << self
      private

      # Agendas the person can see, mapped to whether they're the person's OWN
      # (their events + agendas they own, like a jointly-run "Ours" calendar) vs
      # merely SHARED to them by someone else (a partner's PERSONAL calendar).
      # Both are worth being aware of, but a partner's personal items are NOT
      # the person's own tasks — they get tagged so Buddy treats them as
      # awareness-only, not "your agenda".
      def agenda_source_map(user)
        map = {}
        Agenda.where(user_id: user.id).pluck(:id).each { |id| map[id] = { mine: true } }
        user.shared_agendas.includes(:user).find_each { |ag|
          next if map.key?(ag.id)  # if they own it too, owned wins

          map[ag.id] = { mine: false, owner: ag.user&.first_name.presence || "someone" }
        }
        map
      rescue StandardError => e
        Buddy::Errors.report(section: "context.agenda_source_map", exception: e, user: user)
        Agenda.where(user_id: user.id).pluck(:id).index_with { { mine: true } }
      end

      # Tag an item hash with ownership. Owned items carry no marker (the
      # default is "mine"); a shared-in item is stamped mine:false + owner so
      # the briefing can hold it at arm's length.
      def tag_ownership(hash, source)
        return hash if source.nil? || source[:mine] != false

        hash.merge(mine: false, owner: source[:owner])
      end

      def today_agenda(user, now)
        sources = agenda_source_map(user)
        return [] if sources.empty?

        # Bounded on the PERCEIVED day: the 3am rollover picks WHICH date is
        # "today" (so it matches the Dailies overnight), and the window is that
        # date's midnight→midnight. Midnight bounds keep timed + all-day events
        # consistent and keep a tomorrow all-day event (a birthday, stored at
        # local midnight) out of today. See Buddy::Day.
        day_start = Buddy::Day.at(user, hour: 0, now: now)
        day_end   = day_start + 1.day
        AgendaItem.where(agenda_id: sources.keys)
          .where.not(status: :cancelled)
          .where(start_at: day_start.utc...day_end.utc)
          .includes(:agenda, :agenda_schedule)
          .order(:start_at)
          .limit(20)
          .map { |i|
            tag_ownership(
              {
                id:        i.id,
                time:      (i.all_day ? "all day" : i.start_at.in_time_zone(user.timezone).strftime("%-I:%M %p")),
                title:     i.name,
                cal:       i.agenda&.name,
                kind:      i.kind,
                cadence:   schedule_cadence(i),  # nil = one-off; "every weekday" / "monthly" / ...
                drive_min: drive_minutes(i),     # known travel time, for a soon "leave by" nudge
                # Already happened — a forward-looking briefing skips these
                # instead of recapping a day that's mostly over.
                passed:    (!i.all_day && i.start_at < now ? true : nil),
              }.compact, sources[i.agenda_id]
            )
          }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.today_agenda", exception: e, user: user)
        []
      end

      # The rest of the week (tomorrow through ~a week out). Skews to what's
      # UNUSUAL: each item is tagged `recurring` (routine repeat) vs one-off,
      # and `status` so a cancelled routine ("your standup is off Thursday")
      # can be called out. Day labels are relative so proximity is obvious.
      # Cancelled ONE-OFFs are dropped (noise); cancelled RECURRING are kept
      # (a normally-happening thing not happening is worth a mention).
      def upcoming_agenda(user, now)
        sources = agenda_source_map(user)
        return [] if sources.empty?

        # Rest of the week starts at the end of the perceived today (its
        # midnight), so tomorrow's items don't leak into "today" overnight.
        day_start = Buddy::Day.at(user, hour: 0, now: now)
        cancelled = AgendaItem.statuses[:cancelled]

        AgendaItem.where(agenda_id: sources.keys)
          .where(start_at: (day_start + 1.day).utc...(day_start + UPCOMING_WEEK_WINDOW).utc)
          .where("status != ? OR agenda_schedule_id IS NOT NULL", cancelled)
          .includes(:agenda, :agenda_schedule)
          .order(:start_at)
          .limit(25)
          .map { |i|
            local = i.start_at.in_time_zone(user.timezone)
            tag_ownership(
              {
                day:       day_label(local, user, now),
                time:      (i.all_day ? "all day" : local.strftime("%-I:%M %p")),
                title:     i.name,
                cadence:   schedule_cadence(i),  # nil = one-off
                cancelled: i.cancelled?,
                cal:       i.agenda&.name,
              }.compact, sources[i.agenda_id]
            )
          }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.upcoming_agenda", exception: e, user: user)
        []
      end

      # Relative day label so proximity is obvious at a glance. "today" is the
      # perceived date (3am rollover) so labels line up with the Dailies and the
      # midnight-bounded agenda windows above.
      def day_label(local, user, now)
        days = (local.to_date - Buddy::Day.today(user, now: now)).to_i
        case days
        when 0    then "today"
        when 1    then "tomorrow"
        when 2..6 then local.strftime("%A")           # Mon, Tue, ...
        when 7    then "next #{local.strftime("%A")}"  # a week out
        else           local.strftime("%a %-m/%-d")
        end
      end

      # Human cadence label for a recurring item, nil for a one-off. Lets the
      # briefing tell the "every weekday" stuff it knows cold (gloss it) from
      # a monthly/yearly/every-few-days repeat it may NOT have top of mind
      # (worth a light touch).
      def schedule_cadence(item)
        sched = item.agenda_schedule
        return nil unless sched

        data = (sched.recurrence || {}).with_indifferent_access
        case (data[:freq].to_s.presence || "daily")
        when "daily"    then "daily"
        when "weekdays" then "every weekday"
        when "weekly"
          days = Array(data[:by_day]).map { |d| d.to_s[0, 3].capitalize }
          days.any? ? "weekly (#{days.join(", ")})" : "weekly"
        when "monthly"  then "monthly"
        when "yearly"   then "yearly"
        when "custom"
          iv   = data[:interval].to_i
          unit = data[:unit].to_s.presence || "day"
          iv > 1 ? "every #{iv} #{unit}s" : "#{unit}ly"
        else "recurring"
        end
      rescue StandardError
        "recurring"
      end

      # Known drive time (minutes) from the travel-chain sync, for a soon
      # "leave by" nudge. nil when there's no computed travel.
      def drive_minutes(item)
        travel = item.metadata.is_a?(Hash) ? item.metadata["travel"] : nil
        mins   = travel.is_a?(Hash) ? travel["travel_minutes"].to_i : 0
        mins.positive? ? mins : nil
      end

      # Five buckets with sharply distinct meanings. The primary "what's
      # on today" list is INTENTIONAL only - the user's personal daily
      # rotation + hot picks explicitly pinned for today. Broader
      # matches-today recurring chores go into their own bucket so
      # Buddy doesn't announce "20 pending" when only 7 are actually
      # top-priority. Overdue backlog is separate long-term todo.
      #
      #   pending_today       — dailies + hot_picks (not done). Primary count.
      #   scheduled_today     — matches_day? recurring chores NOT already in
      #                          pending_today (secondary; available if asked).
      #   done_today          — anything from pending_today already done.
      #   hot_picks           — flagged for attention today (subset lens).
      #   overdue_backlog     — marked_due, NOT in any of the above.
      def build_chore_buckets(user, today)
        return default_buckets unless user.respond_to?(:accessible_chores) && user.chore_household_id

        chores = user.accessible_chores.to_a
        by_id  = chores.each_with_object({}) { |c, h| h[c.id] = c }

        # Completion status per chore for today - critical signal so Buddy
        # can say "you've done Water, still pending: Wordle, Teeth" instead
        # of vaguely gesturing at "your dailies". Without this every bucket
        # item looks identical and Buddy can't recommend specifics.
        #
        # Attribution respects `sharing_mode`: a HOUSEHOLD chore (feed the
        # animals, dishes) is "done" for THIS user if ANYONE in the household
        # did it; a PERSONAL chore (brush teeth) is "done" only if THIS user
        # did it. Without the split, Chelsea brushing her teeth would show as
        # Rocco's teeth already done.
        household_user_ids = user.chore_household&.member_user_ids || [user.id]
        completions = ChoreCompletion
          .where(user_id: household_user_ids, day_key: today)
          .pluck(:chore_id, :user_id)
        done_by_anyone = completions.to_set { |cid, _uid| cid }
        done_by_me     = completions.filter_map { |cid, uid| cid if uid == user.id }.to_set
        done_today_ids = chores.each_with_object(Set.new) { |c, set|
          shared = c.respond_to?(:share_household?) && c.share_household?
          set << c.id if (shared ? done_by_anyone : done_by_me).include?(c.id)
        }

        daily_ids = ChoreDaily.for_user(user).limit(20).pluck(:chore_id)
        hot_ids   = ChoreHotPick.for_day(today).where(chore_id: chores.map(&:id)).pluck(:chore_id)
        matches_today_ids = chores.select { |c|
          c.respond_to?(:matches_day?) && c.scheduled? && (safe_matches_day(c, today, user))
        }.map(&:id)

        # Average local-hour of the CURRENT USER's completions per
        # chore. Used to annotate pending items with a "typical_time"
        # label so Buddy can weigh "should I nudge this now" instead of
        # blindly listing everything - e.g. Wordle typically done at 9
        # PM, don't push it at 7 AM. Per-user (not household) because
        # habits are personal: Chelsea and Rocco may do the same chore
        # at very different times. 7-day window keeps it responsive to
        # recent patterns without drifting on old habits.
        typical_hours = compute_typical_hours(user)

        # "Due today" set: chores where TODAY specifically matters -
        # either the schedule matches (matches_day?), or the user pinned
        # it (hot pick), or they manually stamped it as due (marked_due).
        # Lets Buddy distinguish "on the rotation but not scheduled
        # today" from "actually due today".
        due_ids = (matches_today_ids + hot_ids + chores.select { |c|
          c.respond_to?(:marked_due?) && c.marked_due?
        }.map(&:id)).uniq.to_set

        # PRIMARY today list: what the user actively decided is "for today".
        # Dailies are the user's personal rotation; hot_picks are explicit
        # pins. Everything else that just happens to match today's schedule
        # goes to the secondary scheduled_today bucket so the "pending"
        # count reflects intent, not schedule-overlap.
        intentional_ids = (daily_ids + hot_ids).uniq
        pending_ids     = intentional_ids.reject { |id| done_today_ids.include?(id) }
        done_ids        = intentional_ids.select { |id| done_today_ids.include?(id) }
        scheduled_ids   = (matches_today_ids - intentional_ids).reject { |id| done_today_ids.include?(id) }

        overdue = chores.select { |c|
          c.respond_to?(:marked_due?) && c.marked_due? &&
            intentional_ids.exclude?(c.id) && matches_today_ids.exclude?(c.id)
        }.map(&:id)

        {
          pending_today:   pending_ids.filter_map   { |id| slim_chore(by_id[id], typical_hours[id], due_ids) }.first(20),
          done_today:      done_ids.filter_map      { |id| slim_chore(by_id[id], typical_hours[id], due_ids) }.first(20),
          hot_picks:       hot_ids.filter_map       { |id| slim_chore(by_id[id], typical_hours[id], due_ids) }.first(15),
          scheduled_today: scheduled_ids.filter_map { |id| slim_chore(by_id[id], typical_hours[id], due_ids) }.first(20),
          overdue_backlog: overdue.filter_map       { |id| slim_chore(by_id[id], nil, due_ids) }.first(20),
          # The FULL roster of every active (non-archived) chore, names only.
          # This is what `complete_chore` matches against so a chore that
          # isn't due today, isn't overdue, and isn't a hot pick can STILL be
          # recognized as a real chore instead of getting logged as an event.
          all_names:       chores.map(&:name).uniq.sort.first(120),
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.chore_buckets", exception: e, user: user)
        default_buckets
      end

      # Emotional state block. `pet_expression` is the tracked mood —
      # the LLM controls it via `[[mood: X]]` markers, it persists per
      # conversation on byte_conversations.buddy_expression, it ships back in
      # every context turn. `last_check_in` is optional richer detail from an
      # explicit Check-in button tap if one exists in recent history.
      def emotional_state(conversation, now)
        user = conversation.user
        latest_check_in = user.action_events
          .where(name: "check_in")
          .order(timestamp: :desc)
          .limit(1)
          .first
        check_in_summary = if latest_check_in
          # Ship a natural-language vibe description INSTEAD of the raw
          # label word ("good", "low", etc). If the label appears here
          # Buddy pattern-matches and echoes it ("you checked in good") -
          # feels like variable interpolation. The vibe gives the same
          # signal without the specific word to grab.
          mood = latest_check_in.data.is_a?(Hash) ? latest_check_in.data["mood"] : nil
          {
            vibe:      Buddy::Context.mood_vibe_for(mood),
            hours_ago: ((now - latest_check_in.timestamp) / 1.hour).round(1),
          }
        end

        {
          pet_expression: conversation.buddy_expression,
          last_check_in:  check_in_summary,
        }
      end

      def default_buckets
        { pending_today: [], done_today: [], hot_picks: [], scheduled_today: [], overdue_backlog: [], all_names: [] }
      end

      def slim_chore(chore, typical_hour=nil, due_ids=nil)
        return nil if chore.nil?

        out = {
          id:   chore.id,
          name: chore.name,
        }
        out[:freq] = chore.freq.to_s if chore.respond_to?(:freq) && chore.freq.present?
        if chore.respond_to?(:assigned?) && chore.assigned?
          out[:assigned_to] = chore.assigned_to_user&.first_name
        end
        if typical_hour
          out[:typical_hour] = typical_hour.round(1)
          out[:typical_time] = typical_time_label(typical_hour)
        end
        out[:due_today] = due_ids.include?(chore.id) if due_ids
        out
      end

      # Rolling-window average local hour of completion per chore, for
      # THIS user only. Habits are personal - Chelsea and Rocco may do
      # the same shared chore at very different times, so averaging
      # across the household would produce a meaningless midpoint.
      # 7-day window keeps it responsive to the person's current rhythm.
      def compute_typical_hours(user)
        tz = ActiveSupport::TimeZone[user.timezone] || Time.zone
        by_chore = Hash.new { |h, k| h[k] = [] }
        ChoreCompletion
          .where(user_id: user.id)
          .where("completed_at > ?", 7.days.ago)
          .pluck(:chore_id, :completed_at)
          .each { |chore_id, ts|
            # completed_at is timestamp-without-timezone but stores UTC.
            # Attach UTC then convert to the user's local tz to get the
            # local hour they typically finish at.
            local = ts.utc.in_time_zone(tz)
            by_chore[chore_id] << (local.hour + (local.min / 60.0))
          }
        by_chore.transform_values { |hours| hours.sum / hours.length }
      end

      # Human-readable label bucketing the numeric hour. Buddy uses the
      # label naturally in prose ("Wordle is usually a late-evening
      # thing") and the raw hour to reason about "before / after typical".
      def typical_time_label(hour)
        case hour.to_i
        when 5..7   then "early morning"
        when 8..10  then "morning"
        when 11..13 then "midday"
        when 14..16 then "afternoon"
        when 17..19 then "evening"
        when 20..22 then "late evening"
        else             "overnight"
        end
      end

      # `matches_day?` on some chore types raises on malformed recurrence
      # data; a Buddy context build must never blow up over a single bad chore.
      def safe_matches_day(chore, day, user)
        chore.matches_day?(day, user)
      rescue StandardError
        false
      end

      # Only TODAY's events. Previously used a rolling 24h window, which
      # in the morning meant "mostly yesterday" - Buddy would then recap
      # yesterday when asked about today. Anchoring to perceived_today's
      # beginning-of-day matches how the Chores app groups completions
      # and keeps Buddy focused on the current day.
      def recent_events(user, now)
        return [] unless user.respond_to?(:action_events)

        # Buddy::Day rather than Date#beginning_of_day: the latter resolves in
        # Time.zone (UTC app-wide), so on a UTC-6 account "today" opened at 6pm
        # the previous evening and swept yesterday's tail into the briefing —
        # the exact thing the seed prompt then has to talk it out of.
        start_of_today, = Buddy::Day.range(user, now: now)
        user.action_events
          .where(timestamp: start_of_today..)
          .order(timestamp: :desc)
          .limit(15)
          .map { |e|
            age_min = ((now - e.timestamp) / 60).to_i
            {
              id:    e.id,
              name:  e.name,
              at:    e.timestamp.in_time_zone(user.timezone).strftime("%-I:%M %p"),
              # Relative age label. Buddy weights recency by this: "just
              # now" and "N min ago" are live signals, older ones fade.
              # No hard cutoff - Buddy decides based on the label.
              age:   age_label(age_min),
              notes: e.notes.to_s.first(60),
            }
          }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.recent_events", exception: e, user: user)
        []
      end

      # The person's lists, each with the SECTIONS defined on it (produce,
      # dairy, a store name, an aisle). Lets Buddy file a new item under the
      # right existing section instead of guessing a freeform category. Only
      # the section NAMES ship - that's all the add/edit tools need to match.
      # Lists with no sections still appear (bare name) so Buddy knows the
      # roster of lists that exist.
      def lists(user)
        return [] unless user.respond_to?(:ordered_lists)

        user.ordered_lists.includes(:sections).map { |list|
          entry = { name: list.name }
          section_names = list.sections.map(&:name).compact_blank
          entry[:sections] = section_names if section_names.any?
          entry
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.lists", exception: e, user: user)
        []
      end

      def age_label(minutes)
        return "just now" if minutes < 2
        return "#{minutes} min ago" if minutes < 60

        hours = minutes / 60
        return "#{hours}h ago" if hours < 6

        "much earlier today"
      end

      # Pending BuddyReminders scheduled in the next 48 hours, scoped to THIS
      # conversation. Lets Buddy notice existing reminders when the user asks
      # something related, and see recently-scheduled ones to avoid
      # double-booking.
      def upcoming_reminders(conversation, now)
        return [] unless defined?(BuddyReminder)

        tz = conversation.user.timezone
        BuddyReminder.upcoming(now, 48).where(byte_conversation_id: conversation.id).limit(15).map { |r|
          {
            id:      r.id,
            fire_at: r.fire_at.in_time_zone(tz).strftime("%a %-I:%M %p"),
            kind:    r.kind,
            body:    r.body.to_s.first(120),
          }
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.upcoming_reminders", exception: e, user: conversation.user)
        []
      end

      # Countdowns on the clock right now. Buddy could START a timer and then
      # had no idea it existed: prod "Cancel my timers" got "I can't stop a
      # running countdown from here", one minute after Buddy set one itself.
      # Blind is the reason it said no, so this is half of the fix and
      # `cancel_timer` is the other half.
      #
      # A fired-but-unacknowledged timer is deliberately included - it's still
      # on screen, still alarming, and "turn that off" means it.
      def running_timers(user)
        return [] unless defined?(Timer)

        Buddy::Timers.live_for(user).limit(10).map { |t|
          {
            id:        t.id,
            label:     t.name.to_s.presence,
            remaining: timer_remaining(t),
          }.compact
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.running_timers", exception: e, user: user)
        []
      end

      def timer_remaining(timer)
        return "already up, still ringing" if timer.fired?

        left = timer.remaining_ms.to_i / 1000
        state = timer.paused? ? " (paused)" : ""
        "#{Buddy::Timers.humanize_seconds(left)} left#{state}"
      rescue StandardError
        nil
      end

      # Condition-based reminders (BuddyWatch) still waiting for their
      # signal - "remind me next time I'm at Costco", "when I brush my
      # teeth". Lets Buddy see what it's already watching so it doesn't
      # set a duplicate, and can reference/cancel them by id.
      def active_watches(conversation)
        return [] unless defined?(BuddyWatch)

        BuddyWatch.active.where(byte_conversation_id: conversation.id).order(:created_at).limit(15).map { |w|
          {
            id:   w.id,
            when: (w.metadata.is_a?(Hash) ? w.metadata["human_when"].to_s.presence : nil) || w.trigger_scope,
            body: w.body.to_s.first(120),
            # Present only on a hand-written watch. Carried so a "why did that
            # fire" (or a near-duplicate) can be reasoned about from the actual
            # condition rather than the prose around it.
            listener: w.listener,
          }.compact
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.active_watches", exception: e, user: conversation.user)
        []
      end

      # Index of Jil tasks that can be fired by scope name via the
      # `trigger_jil_task` tool. Sourced from ACCESSIBLE tasks (owned +
      # shared), so a task Rocco owns and shares with Chelsea shows up in
      # her Buddy too - and executes as its owner, with the owner's
      # credentials. Gated on the owner's explicit `buddy_enabled` opt-in;
      # without it the index would be ~380 entries of mostly plumbing and
      # Buddy would have no way to tell a scene from a webhook receiver.
      #
      # Covers filtered listeners too, not just bare scopes: `trigger_jil_task`
      # fires `Jil.trigger(user, scope, data)`, so `event:add name::Transaction`
      # is reachable by supplying `add name::Transaction` as data. We ship the
      # FULL listener (not just the scope) because that pattern is what tells
      # Buddy which data the task is filtering on.
      def jil_triggers(user)
        return [] unless defined?(Task)

        user.accessible_tasks.buddy_visible.where.not(listener: [nil, ""])
          .limit(60)
          .pluck(:id, :name, :listener, :description)
          .reject { |_, _, listener, _| listener.to_s.match?(/(^|\s)function\(/i) }
          .map { |id, name, listener, desc|
            {
              id:          id,
              name:        name,
              scope:       listener.to_s.strip.split(":").first,
              listener:    listener.to_s.strip,
              description: desc.to_s.strip.presence,
            }.compact
          }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.jil_triggers", exception: e, user: user)
        []
      end

      # Index of Jil FUNCTION tasks callable via the `call_jil_function`
      # tool. Same accessible + opted-in sourcing as jil_triggers above.
      # We ship the raw signature so Buddy can read the arg names/types
      # without us parsing the Jil signature grammar server-side, plus the
      # description so it knows WHEN the function is the right call.
      def jil_functions(user)
        return [] unless defined?(Task)

        user.accessible_tasks.buddy_visible.functions
          .limit(80)
          .pluck(:id, :name, :listener, :description)
          .map { |id, name, listener, desc|
            { id: id, name: name, signature: listener.to_s.strip, description: desc.to_s.strip.presence }.compact
          }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.jil_functions", exception: e, user: user)
        []
      end

      # The person's saved routines, run by `run_routine`. `steps` is a plain
      # summary rather than the raw payloads: it's there so Buddy can tell them
      # what a routine does and recognise when a request IS one, and the actual
      # arguments only matter at run time, where they're read from the record.
      def routines(user)
        return [] unless user.respond_to?(:buddy_routines)

        user.buddy_routines.enabled.ordered.limit(30).map { |r|
          { id: r.id, name: r.name, description: r.description.presence, steps: r.summary }.compact
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.routines", exception: e, user: user)
        []
      end

      # Brain-dump ideas the person stashed, eligible to resurface now (active,
      # or a defer whose remind_after has passed). Grouped so Today / What now
      # can pull one from the relevant bucket. Each: { id, category, idea,
      # waiting } where `idea` is the summary if Buddy sorted it, else the raw
      # body, and `waiting` is how long it's been sitting.
      #
      # Oldest first: this list is what keeps a loose end from going quietly
      # missing, so the one at most risk of that goes at the top.
      def stashed_ideas(user)
        return [] unless user.respond_to?(:buddy_ideas)

        user.buddy_ideas.surfaceable.order(created_at: :asc).limit(12).map { |i|
          {
            id:       i.id,
            category: i.category,
            idea:     i.summary.presence || i.body.to_s.first(140),
            waiting:  i.waiting_label,
          }
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.stashed_ideas", exception: e, user: user)
        []
      end

      def active_proposals(conversation)
        ByteAction.active
          .where(byte_conversation_id: conversation.id, tool_name: "buddy_proposals")
          .limit(5)
          .flat_map { |a|
            Array(a.buttons).map { |b|
              {
                id:      b["id"],
                tool:    b["tool_name"],
                summary: b["label"],
              }
            }
          }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.active_proposals", exception: e, user: conversation.user)
        []
      end

      # Open questions a partner's companion has relayed to THIS user, still
      # waiting on their answer. Surfaced so that when the user answers in
      # conversation ("tell them tacos", or just "tacos"), Buddy knows to pass
      # it back via relay_answer. Pick-one/pick-any questions also show tappable
      # buttons; relay_answer still works if the user answers in words instead.
      def pending_relays(user)
        BuddyRelay.open_questions_for(user).map { |r|
          { id: r.id, from: r.from_user.first_name, question: r.body, kind: r.kind }
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.pending_relays", exception: e, user: user)
        []
      end

      # The app's own unanswered Prompts (surveys/questions). Deliberately NOT
      # surfaced in the always-loaded at-a-glance block — Buddy pulls these only
      # when the person asks about their prompts, so they don't cost tokens
      # every turn.
      #
      # An INDEX, not the forms themselves: id, title, and the question names as
      # they sit on the row. That's enough to tell which prompt someone means,
      # and no more, on purpose — several prompts build their real fields when
      # opened (see Buddy::PromptForm), so anything richer here would be a
      # skeleton Buddy could mistake for the finished form. `read_prompt` opens
      # one for real.
      def pending_prompts(user)
        return [] unless user.respond_to?(:prompts)

        user.prompts.unanswered.order(created_at: :desc).limit(10).map { |p|
          questions = Array(p.options).map(&:deep_symbolize_keys)
            .reject { |o| o[:type].to_s == "hidden" }
            .filter_map { |o| o[:question].presence }
          { id: p.id, title: p.question, questions: questions }
        }
      rescue StandardError => e
        Buddy::Errors.report(section: "context.pending_prompts", exception: e, user: user)
        []
      end
    end
  end
end
