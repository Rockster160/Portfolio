class AlignAgendasForMultiAccount < ActiveRecord::Migration[7.1]
  def up
    # Replace the old (user_id, source, external_id) uniqueness with one
    # that includes google_account_id, so two GoogleAccounts under the
    # same user can each connect a calendar they share (xxx@group.calendar.google.com).
    remove_index :agendas, name: "index_agendas_on_user_source_external"
    add_index :agendas,
      [:user_id, :source, :google_account_id, :external_id],
      unique: true,
      where:  "source <> 0",
      name:   "index_agendas_on_user_source_account_external"

    # Drop the per-agenda reauth flag — the GoogleAccount now owns this
    # signal (one auth, one reauth state, shared by all the account's
    # synced agendas). The cleanup script ran before this deploy, so no
    # row should still depend on this column.
    remove_column :agendas, :reauth_required_at, :datetime
  end

  def down
    add_column :agendas, :reauth_required_at, :datetime

    remove_index :agendas, name: "index_agendas_on_user_source_account_external"
    add_index :agendas,
      [:user_id, :source, :external_id],
      unique: true,
      where:  "source <> 0",
      name:   "index_agendas_on_user_source_external"
  end
end
