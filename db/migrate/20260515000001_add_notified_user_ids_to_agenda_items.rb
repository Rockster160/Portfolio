class AddNotifiedUserIdsToAgendaItems < ActiveRecord::Migration[7.1]
  def change
    # Single timestamp marking that we've ATTEMPTED to fan out notifications
    # for this item — once set, the worker skips this row forever, regardless
    # of which users were eligible at the time. Prevents retroactive pings
    # when a user toggles notifications on for an agenda whose past events
    # already came and went.
    add_column :agenda_items, :notified_at, :datetime
    add_index :agenda_items, :notified_at
  end
end
