module Buddy
  # Is this chore already recorded for this person, on the day the new
  # completion would land?
  #
  # `merge_key` on `complete_chore` settles that question WITHIN one card, so
  # two identical calls in a single reply collapse into one row. It cannot see
  # a row written two minutes ago on the card above, and that is the shape this
  # went wrong in: prod 5879, a sentence clarifying WHICH pair of chores was
  # Chelsea's, read as a fresh request, wrote `chore_completions` 2869 and 2870
  # against the same two chores she had already been credited for.
  #
  # The tool's own description has told the model to reach for
  # `edit_chore_completion` in exactly this case since it was written. Prose is
  # advice; this is the part that holds.
  module ChoreDuplicate
    module_function

    # A chore meant to be done SEVERAL times a day says so on `target_count`,
    # and for those a second row on the same day is the whole point - four
    # glasses of water is four completions. Only the once-a-day ones are
    # checked, so nothing that legitimately repeats can trip this.
    def existing(chore, user, at: nil)
      return nil unless chore.target_count.to_i == 1

      when_done = at.present? ? (::Time.zone.parse(at.to_s) || ::Time.current) : ::Time.current
      ChoreCompletion.where(
        chore_id: chore.id,
        user_id:  user.id,
        day_key:  ::ChoreDay.current(user, at: when_done),
      ).order(completed_at: :desc).first
    end

    def check!(chore, user, at: nil)
      row = existing(chore, user, at: at)
      return nil if row.nil?

      raise "#{chore.name} is already marked done for #{user.first_name} on " \
            "#{::ChoreDay.current(user, at: row.completed_at).strftime("%b %-d")} - " \
            "to change that one use edit_chore_completion, and to take it off " \
            "use undo_chore_completion"
    end
  end
end
