class AddGoogleSyncFieldsToAgendas < ActiveRecord::Migration[7.1]
  def change
    # `source` distinguishes user-owned agendas from agendas materialized by
    # an upstream system (currently just Google Calendar). Externally-managed
    # agendas are read-only in the UI; the sync pipeline writes through the
    # model directly and bypasses controller guards.
    add_column :agendas, :source, :integer, default: 0, null: false
    add_column :agendas, :external_id, :text # Google calendar id

    # Incremental-sync cursor returned by events.list. Persisted between
    # sync runs so we only pull deltas after the first full import.
    add_column :agendas, :sync_token, :text
    add_column :agendas, :synced_at, :datetime

    # Push-notification channel (events.watch). Channels have a hard ~7d TTL —
    # `watch_expires_at` drives the channel-renewal worker.
    add_column :agendas, :watch_channel_id, :text
    add_column :agendas, :watch_resource_id, :text
    add_column :agendas, :watch_expires_at, :datetime

    # Per-user uniqueness of the external (Google) calendar id, scoped to
    # non-user sources so user-owned rows aren't impacted.
    add_index :agendas, [:user_id, :source, :external_id],
      unique: true,
      where:  "source <> 0",
      name:   "index_agendas_on_user_source_external"

    # Webhook handler looks up agendas by the X-Goog-Channel-Id header.
    add_index :agendas, :watch_channel_id,
      unique: true,
      where:  "watch_channel_id IS NOT NULL"

    # Renewal worker pulls upcoming-expiry agendas via this index.
    add_index :agendas, :watch_expires_at,
      where: "watch_expires_at IS NOT NULL"
  end
end
