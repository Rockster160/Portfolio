# Changing ONE date of a repeating thing.
#
# A repeating item's occurrences exist in two shapes and a person can't tell
# them apart: the next 30 hours' worth have rows (`AgendaSchedule::
# MATERIALIZE_WINDOW`), and everything past that is a phantom built from the
# rule on demand. That split is an implementation detail of how the calendar is
# stored, and nothing outside this file should have to know about it — a
# Tuesday four weeks out is as editable as tomorrow's.
#
# Three steps, and all three matter:
#
#   1. STAMP THE DETACH. `detached_at` marks the row as an exception to its
#      rule, and `original_start_at` remembers which date it came from so
#      "Restore to cycle" can put it back. First detach only — a second edit of
#      an already-detached row is just an edit.
#   2. MATERIALIZE OR UPDATE. A phantom becomes a real row carrying the change;
#      a row that already exists takes it directly.
#   3. EXCLUDE THE ORIGINAL DATE on the parent schedule, or the rule keeps
#      generating a phantom on the date the row just moved off and the evening
#      shows up twice.
#
# Extracted from AgendaItemsController#materialize_with so Buddy's
# `edit_agenda_item` lands the same row the UI does. Two implementations of
# step 3 would disagree eventually, and the failure is a duplicate occurrence
# nobody can account for.
module AgendaOccurrence
  module_function

  def apply!(item, attrs)
    schedule = item.agenda_schedule
    date     = item.occurrence_date
    # Read BEFORE the save: `detached_at` is about to be true either way.
    detaching = schedule.present? && !item.detached? && attrs[:detached_at].present?

    item.phantom? ? item.materialize!(attrs) : item.update!(attrs)
    schedule.add_excluded_date!(date) if detaching
    item
  end

  # What turns an occurrence into an exception. Kept apart from `apply!`
  # because not every single-occurrence write is one: ticking a recurring
  # to-do off materializes a row without detaching it from its rule, and
  # stamping it there would quietly break the cycle.
  def detach_stamps(item)
    return {} unless item.recurring? && !item.detached?

    { detached_at: Time.current, original_start_at: item.start_at }
  end

  # The exact reverse of `apply!` on an occurrence that had no row before: put
  # the date back on the rule, then drop the exception. Un-exclude FIRST, so a
  # failure leaves a row rather than a hole in the series.
  #
  # This is what "Restore to cycle" does in the app, and it is what undoing a
  # Buddy edit of a not-yet-written-down occurrence has to do. Reverting the
  # FIELDS instead would leave a detached row holding the rule's own values
  # next to an excluded date — invisible on the calendar, and the next change
  # to the series would skip straight over it.
  # Returns the row it put back, or nil when there was nothing to put back — so
  # a caller can say "that one is on its normal schedule already" rather than
  # reporting a no-op as an undo.
  def reattach!(item)
    schedule = item.agenda_schedule
    return nil if schedule.nil? || !item.detached?

    date = item.original_start_at&.in_time_zone(item.user.timezone)&.to_date
    schedule.remove_excluded_date!(date) if date
    item.destroy!
    item
  end
end
