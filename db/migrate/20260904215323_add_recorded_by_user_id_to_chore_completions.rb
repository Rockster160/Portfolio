class AddRecordedByUserIdToChoreCompletions < ActiveRecord::Migration[7.1]
  def change
    # Who pressed the button, when that is not the person being credited.
    # NULL means they are the same person, which is every ordinary tap and
    # every row written before this column existed — so nothing needs
    # backfilling and the common case stays one column narrower.
    #
    # Until now a credited completion recorded only the credited user, which
    # made the recorder's own automations unreachable: `trigger_target_users`
    # fires at the completion's `user`, so marking a personal chore done on
    # someone else's behalf sent the trigger to THEM and silently no-opped
    # every RecordLink and Jil task belonging to the person who did the
    # marking.
    add_reference :chore_completions, :recorded_by_user, null: true, foreign_key: { to_table: :users }
  end
end
