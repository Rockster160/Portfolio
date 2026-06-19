class AddAgendaIdUpdatedAtIndexToAgendaItems < ActiveRecord::Migration[7.1]
  # Composite index for the delta endpoint:
  #   AgendaItem
  #     .where(agenda_id: accessible_agenda_ids)
  #     .where("updated_at >= ?", since)
  #     .order(:updated_at)
  #
  # Without this index, the scan starts from the agenda_id alone and then
  # filters on updated_at row-by-row, which gets expensive once an agenda
  # has thousands of historical items (and the user has many agendas).
  # The composite lets Postgres satisfy both the agenda restriction and
  # the updated_at cutoff via a single index range scan.
  #
  # Concurrent so prod isn't blocked while the index builds — agenda_items
  # gets writes constantly (Google sync + user mutations).
  disable_ddl_transaction!

  def change
    add_index :agenda_items, [:agenda_id, :updated_at],
      name: "index_agenda_items_on_agenda_id_and_updated_at",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
