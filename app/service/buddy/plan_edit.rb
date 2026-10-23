module Buddy
  # What `edit_plan` works out and then does. Resolving is every check; applying
  # is only writes, so nothing moves unless every part of the change can.
  #
  # The resolved form is a list of `{model, id, attrs}` - plain column values,
  # JSON-safe - because it rides on a checklist row between the two halves and
  # is what the undo puts back from.
  class PlanEdit
    SHIFT_RX = /\A([+-])\s*(\d+)\s*(m|mins?|minutes?|h|hrs?|hours?|d|days?)\z/i
    UNIT_SECONDS = { "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

    def self.apply!(ctx, payload)
      reverts = []
      ApplicationRecord.transaction do
        # Watches first: a reminder's stop rule is its own row in the plan, and
        # going after the reminder first could leave nothing to find.
        Array(payload[:cancel]).sort_by { |row| row.to_h.with_indifferent_access[:model] == "BuddyWatch" ? 0 : 1 }.each { |raw|
          row = raw.to_h.with_indifferent_access
          rec = record(ctx.user, row)
          next if rec.nil?

          reverts << {
            op:      :recreated,
            model:   rec.class.name,
            attrs:   rec.attributes.except("id", "created_at", "updated_at"),
            summary: "put the plan back",
          }
          rec.destroy!
        }
        Array(payload[:changes]).each { |raw|
          row   = raw.to_h.with_indifferent_access
          rec   = record(ctx.user, row)
          raise "part of that plan is already gone" if rec.nil?

          attrs = row[:attrs].to_h
          reverts << { op: :updated, model: rec.class.name, id: rec.id, before: rec.attributes.slice(*attrs.keys), summary: "put the plan back" }
          rec.update!(attrs)
        }
      end
      { title: payload[:title], lines: payload[:lines], reverts: reverts }
    end

    def self.record(user, row)
      klass = row[:model].to_s == "BuddyWatch" ? BuddyWatch : BuddyReminder
      klass.find_by(user_id: user.id, id: row[:id])
    end

    def initialize(ctx, payload)
      @ctx     = ctx
      @user    = ctx.user
      @payload = payload
      @changes = Hash.new { |hash, key| hash[key] = {} }
      @lines   = []
    end

    def resolve
      @parts = target_parts
      raise "nothing left in that plan - it may have finished already" if @parts.empty?

      title = "Change #{Buddy::Plan.summary_of(@parts, @user).truncate(80)}"
      return cancel_all(title) if truthy?(:cancel)

      retime
      recondition
      rewatch
      restep
      reword
      readdress
      rebound
      raise "nothing to change - say what should be different" if @changes.empty?

      {
        summary:  "#{title}: #{@lines.join("; ")}?",
        resolved: {
          changes: @changes.map { |(model, id), attrs| { model: model, id: id, attrs: JSON.parse(attrs.to_json) } },
          title:   title,
          lines:   @lines,
        },
      }
    end

    private

    def truthy?(key)
      ActiveModel::Type::Boolean.new.cast(@payload[key]).present?
    end

    def given?(key)
      !@payload[key].nil? && @payload[key].to_s.strip != ""
    end

    # A row id is that ONE part - how a change that could mean either of two
    # parts gets aimed. The plan id or words reach the whole plan.
    def target_parts
      needle = @payload[:plan].to_s.strip
      if needle.match?(/\A#?\d+\z/)
        id   = needle.delete("#").to_i
        rows = [BuddyReminder, BuddyWatch].filter_map { |klass| klass.find_by(user_id: @user.id, id: id, fired_at: nil) }
        raise "nothing live has the id #{id}" if rows.empty?
        raise "reminder #{id} and watch #{id} are both live - use the plan id from context" if rows.length > 1

        return [rows.first]
      end

      Buddy::Plan.parts(@user, Buddy::Plan.find!(@user, needle))
    end

    def cancel_all(title)
      {
        summary:  "Remove #{Buddy::Plan.summary_of(@parts, @user)}?",
        resolved: {
          cancel: @parts.map { |row| { model: row.class.name, id: row.id } },
          title:  title.sub(/\AChange/, "Removed"),
          lines:  [],
        },
      }
    end

    def reminders = @parts.grep(BuddyReminder)

    # The rule that switches a reminder off belongs to the plan, but it isn't
    # a thing the plan DOES - it never speaks, runs or waits on a condition.
    def watches = @parts.grep(BuddyWatch).reject(&:cancels?)

    def acting = reminders + watches

    def change(row, attrs)
      @changes[[row.class.name, row.id]].merge!(attrs)
    end

    def only_one(rows, what)
      raise "this plan has nothing that #{what}" if rows.empty?

      if rows.length > 1
        names = rows.map { |row| "##{row.id} #{Buddy::Plan.part_phrase(row, @user)}" }.join("; ")
        raise "#{rows.length} parts of this plan #{what} - pass one's id as `plan`: #{names}"
      end

      rows.first
    end

    # ---- when ----------------------------------------------------------------

    def retime
      return unless given?(:shift) || given?(:at)
      raise "shift or at, not both" if given?(:shift) && given?(:at)

      timed = reminders.reject(&:anchored?).select(&:fire_at)
      if timed.empty?
        anchored = reminders.select(&:anchored?)
        raise "its times follow #{::Anchor.describe(anchored.first.anchor)}, so there's no clock to move" if anchored.any?

        raise "nothing in this plan goes off at a time - it waits for something to happen"
      end

      given?(:shift) ? shift_all(timed) : move_one(only_one(timed, "go off at a time"))
    end

    def shift_all(timed)
      match = @payload[:shift].to_s.strip.match(SHIFT_RX)
      raise "couldn't read #{@payload[:shift].inspect} as a shift (want \"+1h\", \"-30m\", \"+1d\")" if match.nil?

      delta = match[2].to_i * UNIT_SECONDS.fetch(match[3][0].downcase) * (match[1] == "-" ? -1 : 1)
      timed.each { |row|
        if row.recurring? && delta.abs >= 1.day
          raise "\"#{row.body.truncate(30)}\" repeats - move its time of day, not the day"
        end

        place(row, row.fire_at + delta)
      }
      @lines << "#{match[1] == "-" ? "earlier" : "later"} by #{Buddy::Timers.humanize_seconds(delta.abs)}"
    end

    def move_one(row)
      at = @ctx.resolve_time(@payload[:at])
      raise "couldn't work out the new time" if at.nil?

      place(row, at)
      @lines << "\"#{row.body.truncate(30)}\" at #{Buddy::Clock.day_at(at, zone: @user.timezone)}"
    end

    # A repeat keeps its shape and only the hour moves, the way move_reminder
    # does it, so the next one AND every one after it land at the new time.
    def place(row, at)
      raise "\"#{row.body.truncate(30)}\" would land in the past" if at < Time.current

      attrs = { fire_at: at.iso8601, fired_at: nil }
      zoned = at.in_time_zone(@user.timezone)
      attrs[:recurrence] = row.recurrence.merge("at" => zoned.strftime("%H:%M")) if row.recurring?
      change(row, attrs)
    end

    # ---- what has to hold ----------------------------------------------------

    def recondition
      return if @payload[:only_if].nil?

      match = truthy?(:only_if_any) ? :any : :all
      condition = ScheduleCondition.from_rows(@payload[:only_if], match: match)
      ScheduleCondition.validate!(condition, @user)
      acting.each { |row| change(row, condition: condition) }
      @lines << (condition ? ScheduleCondition.describe(condition) : "no conditions")
    end

    # ---- what its watch waits for --------------------------------------------

    def rewatch
      return unless given?(:trigger)

      watch = only_one(watches, "waits for something")
      found = Buddy::WatchCondition.resolve(@payload.slice(:trigger, :target, :listener, :when_phrase, :past_phrase), @ctx)
      raise "not sure where #{found.place_name.presence || "that"} is - what's the address?" if found.place_known == false
      raise "that one is watched under someone else - set a new one instead" if found.owner.id != watch.user_id

      human = watch.one_shot ? found.human : Buddy::WatchCondition.repeating_phrase(found.human)
      meta  = watch.metadata.to_h.merge("human_when" => human, "human_past" => found.past).compact
      change(watch, trigger_scope: found.scope, listener: found.listener, metadata: meta)
      @lines << "now #{human}"
    end

    # ---- what it runs --------------------------------------------------------

    def restep
      return unless given?(:steps) || given?(:add_steps)
      raise "steps or add_steps, not both" if given?(:steps) && given?(:add_steps)

      runners = acting.select { |row| runs?(row) }
      row = runners.one? ? runners.first : only_one(runners.presence || acting, "runs something")
      added = Buddy::Routines.sanitize(Buddy::Routines.parse_rows(@payload[:steps] || @payload[:add_steps]), @ctx)
      steps = given?(:add_steps) ? current_steps(row) + added : added
      phrase = steps.map { |step| BuddyRoutine.step_phrase(step) }.join(", ")

      if row.is_a?(BuddyWatch)
        raise "that one tells #{row.notify_user&.first_name || "someone"} something; it can't run steps" if row.notify_user_id

        meta = row.metadata.to_h.except("run_call", "run_scope", "run_routine_id", "timer_seconds")
        change(row, kind: "action", metadata: meta.merge("run_steps" => steps, "run_task_name" => phrase))
      else
        raise "that one goes to #{row.notify_user&.first_name || "someone"}; it can't run steps" if row.notify_user_id

        change(row, action: steps.map { |step| { "tool" => step["tool_name"], "payload" => step["payload"] } })
      end
      @lines << "runs #{phrase}"
    end

    def runs?(row)
      return row.action_calls.any? if row.is_a?(BuddyReminder)

      row.action?
    end

    # What a part already runs, as routine steps. A saved routine or a single
    # task can't be added to in place, because the routine is shared with
    # everything else that runs it.
    def current_steps(row)
      return row.action_calls.map { |call| BuddyRoutine.step(call[:tool_name], call[:payload]) } if row.is_a?(BuddyReminder)
      return row.run_steps if row.run_steps.any?
      raise "that one runs #{row.run_task_name || "a saved routine"} - pass `steps` with everything it should run" if row.action?

      []
    end

    # ---- words and people ----------------------------------------------------

    def reword
      return unless given?(:text)

      row = only_one(acting, "says something")
      change(row, body: @payload[:text].to_s.strip.first(500))
      @lines << "says \"#{@payload[:text].to_s.strip.truncate(40)}\""
    end

    def readdress
      return unless given?(:notify)

      wanted = @payload[:notify].to_s.strip
      person = %w[me myself].include?(wanted.downcase) ? @user : @ctx.resolve_household_user(wanted)
      raise "I'm not sure who #{wanted} is" if person.nil?

      acting.each { |row|
        if runs?(row) || (row.is_a?(BuddyWatch) && (row.timer? || row.alarm?))
          raise "\"#{row.body.truncate(30)}\" runs something rather than telling anyone"
        end

        change(row, notify_user_id: (person.id == row.user_id ? nil : person.id))
      }
      @lines << (person.id == @user.id ? "for you" : "for #{person.first_name}")
    end

    def rebound
      return unless given?(:expires)

      ends = @ctx.end_of_day_for(@payload[:expires])
      raise "couldn't read #{@payload[:expires].inspect} as a day" if ends.nil?

      only = watches
      raise "nothing in this plan waits for something to happen" if only.empty?

      only.each { |row| change(row, expires_at: ends.iso8601) }
      @lines << "until #{ends.strftime("%b %-e")}"
    end
  end
end
