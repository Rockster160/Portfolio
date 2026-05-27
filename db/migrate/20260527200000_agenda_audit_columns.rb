class AgendaAuditColumns < ActiveRecord::Migration[7.1]
  # Single migration covering every schema change from the agenda audit:
  #
  #   * agenda_items.local_color   — user color override that stays local
  #     even on Google-synced rows (Google's colorId is server-owned).
  #   * agenda_items.cancelled_at  — when the row was soft-cancelled. The
  #     `status` enum (next column) is what filters; this is just an
  #     informational "when".
  #   * agenda_items.status        — int-backed enum: confirmed(0) /
  #     tentative(1) / cancelled(2). Mirrors Google's status vocabulary.
  #   * agendas.sync_reason        — last sync trigger label
  #     (webhook / poll / manual) — shown on /agenda/manage.
  #   * google_accounts.disconnected_at — soft-disconnect tombstone. Lets
  #     the connection picker re-list a disconnected account as a
  #     "Reconnect" option without losing the audit trail.
  #
  # AgendaShare :owner role is enum-value-only (no schema change) — the
  # existing :permission column already holds 2 for the new role.
  def change
    add_column :agenda_items, :local_color,  :string
    add_column :agenda_items, :cancelled_at, :datetime
    add_column :agenda_items, :status,       :integer, default: 0, null: false

    add_index :agenda_items, :status
    add_index :agenda_items, :cancelled_at, where: "cancelled_at IS NOT NULL"

    add_column :agendas, :sync_reason, :string

    add_column :google_accounts, :disconnected_at, :datetime
  end
end
