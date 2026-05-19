class AddOriginalStartAtToAgendaItems < ActiveRecord::Migration[7.1]
  def change
    # When a recurring occurrence is broken out into a one-off (detached),
    # this stores its pre-detach start_at so "Restore to cycle" knows which
    # date to un-exclude on the parent schedule.
    add_column :agenda_items, :original_start_at, :datetime
  end
end
