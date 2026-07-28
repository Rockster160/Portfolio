module Buddy
  # Snapshot injected into the system prompt each turn so Buddy can reference
  # today's agenda, recent events, chore state, etc. Kept intentionally small
  # (target < 1.5 KB) — this ships with every turn.
  module Context
    module_function

    RECENT_EVENT_WINDOW = 24.hours
    UPCOMING_AGENDA_WINDOW = 24.hours
    # Rest-of-week lookahead (past today). 8 days so "exactly a week from now"
    # still lands in the window.
    UPCOMING_WEEK_WINDOW = 8.days

    def build(user)
      tz = user.timezone
      now = Time.current.in_time_zone(tz)
      today = user.perceived_today

      chore_buckets = build_chore_buckets(user, today)

      {
        now_local:         now.strftime("%a %Y-%m-%d %-I:%M %p %Z"),
        timezone:          tz,
        user_first_name:   user.first_name,
        emotional_state:   emotional_state(user, now),          # current mood + pet expression
        today_agenda:      today_agenda(user, now),
        upcoming_agenda:   upcoming_agenda(user, now),          # rest-of-week, unusual-first
        # Two explicit lists per bucket - PENDING and DONE_TODAY - so
        # Buddy can never confuse "what's left" with "what's finished".
        # The previous mixed-list-with-done_today-flag was getting
        # glossed over (LLM reads the list, ignores the flag).
        chores_pending_today:    chore_buckets[:pending_today],
        chores_done_today:       chore_buckets[:done_today],
        chores_hot_picks:        chore_buckets[:hot_picks],       # attention items
        chores_scheduled_today:  chore_buckets[:scheduled_today], # recurring chores landing today but NOT in the user's intentional list
        chores_overdue_backlog:  chore_buckets[:overdue_backlog], # long-term todo, NOT all-must-do-today
        chores_all:              chore_buckets[:all_names],       # EVERY active chore name - the match roster for complete_chore
        recent_events:       recent_events(user, now),
        active_proposals:    active_proposals(user),
        upcoming_reminders:  upcoming_reminders(user, now),
        jil_triggers:        jil_triggers(user),
        jil_functions:       jil_functions(user),
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

      def today_agenda(user, now)
        agenda_ids = Agenda.where(user_id: user.id).pluck(:id)
        return [] if agenda_ids.empty?

        AgendaItem.where(agenda_id: agenda_ids)
          .where.not(status: :cancelled)
          .where("start_at >= ? AND start_at < ?", now.beginning_of_day.utc, (now + UPCOMING_AGENDA_WINDOW).utc)
          .includes(:agenda, :agenda_schedule)
          .order(:start_at)
          .limit(20)
          .map { |i|
            {
              id:        i.id,
              time:      (i.all_day ? "all day" : i.start_at.in_time_zone(user.timezone).strftime("%-I:%M %p")),
              title:     i.name,
              cal:       i.agenda&.name,
              kind:      i.kind,
              cadence:   schedule_cadence(i),  # nil = one-off; "every weekday" / "monthly" / ...
              drive_min: drive_minutes(i),     # known travel time, for a soon "leave by" nudge
            }.compact
          }
      rescue => e
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
        agenda_ids = Agenda.where(user_id: user.id).pluck(:id)
        return [] if agenda_ids.empty?

        start_from = (now.beginning_of_day + 1.day)
        cancelled  = AgendaItem.statuses[:cancelled]

        AgendaItem.where(agenda_id: agenda_ids)
          .where("start_at >= ? AND start_at < ?", start_from.utc, (now.beginning_of_day + UPCOMING_WEEK_WINDOW).utc)
          .where("status != ? OR agenda_schedule_id IS NOT NULL", cancelled)
          .includes(:agenda, :agenda_schedule)
          .order(:start_at)
          .limit(25)
          .map { |i|
            local = i.start_at.in_time_zone(user.timezone)
            {
              day:       day_label(local, now),
              time:      (i.all_day ? "all day" : local.strftime("%-I:%M %p")),
              title:     i.name,
              cadence:   schedule_cadence(i),  # nil = one-off
              cancelled: i.cancelled?,
              cal:       i.agenda&.name,
            }.compact
          }
      rescue => e
        Buddy::Errors.report(section: "context.upcoming_agenda", exception: e, user: user)
        []
      end

      # Relative day label so proximity is obvious at a glance.
      def day_label(local, now)
        days = (local.to_date - now.to_date).to_i
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
      rescue
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
        household_user_ids = user.chore_household&.member_user_ids || [user.id]
        done_today_ids = ChoreCompletion
          .where(user_id: household_user_ids, day_key: today)
          .pluck(:chore_id)
          .to_set

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
            !intentional_ids.include?(c.id) && !matches_today_ids.include?(c.id)
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
      rescue => e
        Buddy::Errors.report(section: "context.chore_buckets", exception: e, user: user)
        default_buckets
      end

      # Emotional state block. `pet_expression` is the tracked mood —
      # the LLM controls it via `[[mood: X]]` markers, it persists on
      # users.buddy_expression, it ships back in every context turn.
      # `last_check_in` is optional richer detail from an explicit
      # Check-in button tap if one exists in recent history.
      def emotional_state(user, now)
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
          pet_expression: user.buddy_expression,
          last_check_in:  check_in_summary,
        }
      end


      def default_buckets
        { pending_today: [], done_today: [], hot_picks: [], scheduled_today: [], overdue_backlog: [], all_names: [] }
      end

      def slim_chore(chore, typical_hour = nil, due_ids = nil)
        return nil if chore.nil?

        out = {
          id:         chore.id,
          name:       chore.name,
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
            by_chore[chore_id] << local.hour + (local.min / 60.0)
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
      rescue
        false
      end

      # Only TODAY's events. Previously used a rolling 24h window, which
      # in the morning meant "mostly yesterday" - Buddy would then recap
      # yesterday when asked about today. Anchoring to perceived_today's
      # beginning-of-day matches how the Chores app groups completions
      # and keeps Buddy focused on the current day.
      def recent_events(user, now)
        return [] unless user.respond_to?(:action_events)

        start_of_today = user.perceived_today.beginning_of_day
        user.action_events
          .where("timestamp >= ?", start_of_today)
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
      rescue => e
        Buddy::Errors.report(section: "context.recent_events", exception: e, user: user)
        []
      end

      def age_label(minutes)
        return "just now"       if minutes < 2
        return "#{minutes} min ago" if minutes < 60
        hours = minutes / 60
        return "#{hours}h ago"  if hours < 6
        "much earlier today"
      end

      # Pending BuddyReminders scheduled in the next 48 hours. Lets Buddy
      # notice existing reminders when the user asks something related,
      # and see recently-scheduled ones to avoid double-booking.
      def upcoming_reminders(user, now)
        return [] unless defined?(BuddyReminder)

        BuddyReminder.upcoming(now, 48).where(user_id: user.id).limit(15).map { |r|
          {
            id:      r.id,
            fire_at: r.fire_at.in_time_zone(user.timezone).strftime("%a %-I:%M %p"),
            kind:    r.kind,
            body:    r.body.to_s.first(120),
          }
        }
      rescue => e
        Buddy::Errors.report(section: "context.upcoming_reminders", exception: e, user: user)
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
      rescue => e
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
      rescue => e
        Buddy::Errors.report(section: "context.jil_functions", exception: e, user: user)
        []
      end

      def active_proposals(user)
        ByteAction.active
          .where(user_id: user.id, tool_name: "buddy_proposals")
          .limit(5)
          .flat_map { |a|
            Array(a.buttons).map { |b|
              {
                id:   b["id"],
                tool: b["tool_name"],
                summary: b["label"],
              }
            }
          }
      rescue => e
        Buddy::Errors.report(section: "context.active_proposals", exception: e, user: user)
        []
      end
    end
  end
end
