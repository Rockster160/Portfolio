class AddDefaultAgendaToAgendaPreferences < ActiveRecord::Migration[7.1]
  # Where an item goes when nobody names a calendar.
  #
  # There was no such setting, so both Byte and the app fell back to the
  # lowest-id writable agenda — which meant "Ours should be the default unless I
  # specify" could be said any number of times and never take, because the
  # personal calendar is always older.
  #
  # nullify rather than cascade: deleting a calendar should clear the preference
  # and fall back, not delete the person's whole filter row with it.
  def change
    add_reference :agenda_preferences, :default_agenda,
      null:        true,
      foreign_key: { to_table: :agendas, on_delete: :nullify },
      index:       false
  end
end
