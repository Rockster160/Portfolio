module Buddy
  # Turning a one-off agenda item's attributes plus a recurrence rule into the
  # AgendaSchedule that owns the series.
  #
  # The two shapes disagree about where the time of day lives, which is the
  # whole reason this is a translation and not a merge. A rule from
  # Buddy::RepeatSpec carries `at` ("09:00"), `starts_on` and `until_on` inside
  # the hash, because a BuddyReminder has no columns for them; AgendaSchedule
  # has all three as real columns and wants the rule to hold only the pattern.
  # Leaving `at` in the jsonb gets it silently ignored and every occurrence
  # lands at midnight.
  module AgendaSeries
    module_function

    # Keys that are columns here rather than part of the pattern.
    HOISTED = %w[at starts_on until_on].freeze

    def create!(agenda, recurrence, attrs, duration: nil)
      rule = recurrence.to_h.transform_keys(&:to_s)
      at, starts_on, until_on = HOISTED.map { |key| rule.delete(key) }

      agenda.agenda_schedules.create!(
        name:                 attrs[:name],
        kind:                 attrs[:kind],
        recurrence:           rule,
        starts_on:            starts_on.presence || attrs[:start_at].to_date,
        start_time:           at.presence || attrs[:start_at].strftime("%H:%M"),
        until_on:             until_on.presence,
        all_day:              attrs[:all_day],
        location:             attrs[:location],
        # Required on an event, meaningless on a task - the same split
        # add_agenda_item makes when deciding whether to set `end_at`.
        duration_minutes:     (duration if attrs[:kind].to_sym == :event),
        # `.to_i` on a missing key is 0, which is a real setting rather than an
        # absent one - so the rule's own default is spelled out.
        arrive_early_minutes: (attrs[:arrive_early_minutes] || ::AgendaItem::DEFAULT_ARRIVE_EARLY_MINUTES).to_i,
      )
    end
  end
end
