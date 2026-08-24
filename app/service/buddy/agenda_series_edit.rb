module Buddy
  # Applying an edit_agenda_item change to the RULE rather than to one
  # occurrence of it.
  #
  # Two things send a change here. An occurrence further out than
  # AgendaSchedule::MATERIALIZE_WINDOW has no row of its own, so the rule is
  # the only thing there is to edit; and a move between calendars means the
  # series unless they say otherwise, because changing the one materialized
  # Monday leaves the rule pointing at the old calendar and next Monday is back
  # where it started. Prod 4462-4471 was both at once.
  #
  # The occurrences follow on their own: AgendaSchedule re-materializes on a
  # name/time/duration/kind change and moves its rows on an agenda change, so
  # everything here is one `update!`.
  module AgendaSeriesEdit
    module_function

    def call(payload, ctx)
      schedule = AgendaSchedule.find(payload[:agenda_schedule_id])
      attrs    = attrs_for(payload, schedule, ctx)
      prior    = schedule.name
      before   = attrs.keys.index_with { |k| schedule.public_send(k) }  # old values, for undo
      schedule.update!(attrs) unless attrs.empty?

      {
        agenda_schedule_id: schedule.id,
        updated_fields:     attrs.keys,
        revert:             {
          op:      "updated",
          model:   "AgendaSchedule",
          id:      schedule.id,
          before:  before,
          summary: "reverted #{prior}",
        },
      }
    end

    def attrs_for(payload, schedule, ctx)
      # Cancelling a series is ending it, which is a different ask from editing
      # one - and answering it here would silently take every future occurrence
      # off the calendar under a receipt that says "updated".
      raise "cancelling a whole series isn't something I can do yet" if payload[:cancelled] == "true"

      attrs = {}
      attrs[:name]      = payload[:title]    if payload[:title].present?
      attrs[:location]  = payload[:location] if payload[:location].present?
      attrs[:agenda_id] = payload[:agenda_id] if payload[:agenda_id].present?

      # The schedule stores a wall-clock TIME OF DAY, not an instant: `at` names
      # the hour every occurrence starts at, and the dates stay where the rule
      # puts them.
      if payload[:at].present? && (start = ctx.resolve_time(payload[:at]))
        attrs[:start_time] = start.in_time_zone(ctx.user.timezone).strftime("%H:%M")
      end

      becoming = (payload[:kind].presence || schedule.kind).to_s
      attrs[:kind] = becoming if becoming != schedule.kind

      # Only an event has a length. A to-do being made into an event needs one
      # it has never had, and the same 30 minutes add_agenda_item gives a new
      # one; a rule going the other way drops it, or `duration_required_for_event`
      # has nothing to validate against and the column keeps a span the row no
      # longer renders.
      if becoming == "event"
        minutes = payload[:duration].presence&.to_i || schedule.duration_minutes || 30
        attrs[:duration_minutes] = minutes if minutes != schedule.duration_minutes
      elsif schedule.duration_minutes.present?
        attrs[:duration_minutes] = nil
      end

      attrs
    end

    def receipt(result, _ctx)
      schedule = AgendaSchedule.find_by(id: result[:agenda_schedule_id])
      name     = schedule&.name || "that series"
      fields   = Array(result[:updated_fields]).map(&:to_s)
      phrase   = Buddy::ReminderPresenter.repeat_phrase(schedule&.recurrence || {})

      return "Moved every #{name} to #{schedule&.agenda&.name} ✓" if fields.include?("agenda_id")
      return "Updated #{name} ✓" unless fields.include?("start_time") && schedule

      "#{name} #{phrase} → #{schedule.start_time.strftime("%-I:%M %p")} ✓"
    end
  end
end
