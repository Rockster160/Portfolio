class AddClientMutationIdToAgendaItems < ActiveRecord::Migration[7.1]
  # Mirrors the Chores PWA's offline-first contract: every mutation the
  # FE makes carries a client-generated UUID so the server can dedupe
  # replayed POSTs after a network drop. Without this column, a queue
  # that fired twice (offline-then-online, two tabs, browser killed
  # mid-flight) would create duplicate rows.
  #
  # Unique partial index: scoped to one agenda's row (server enforces
  # ownership upstream) and only enforced when the value is present
  # (legacy / non-PWA writes can still skip it).
  #
  # Concurrent so prod isn't blocked while the index builds — Google
  # sync + user mutations write to agenda_items constantly.
  disable_ddl_transaction!

  def change
    add_column :agenda_items, :client_mutation_id, :string,
      if_not_exists: true
    add_index :agenda_items, :client_mutation_id,
      name:      "index_agenda_items_on_client_mutation_id",
      unique:    true,
      where:     "client_mutation_id IS NOT NULL",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
