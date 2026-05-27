class AddLocallyModifiedAtToAgendaItems < ActiveRecord::Migration[7.1]
  def change
    # Set by the items controller whenever a user edits an externally-synced
    # item via the UI (excluding completion-only toggles, which don't map to
    # any Google-side field). When present, GoogleCalendar::Sync skips the
    # item so the user's overrides aren't clobbered by the next pull.
    add_column :agenda_items, :locally_modified_at, :datetime
  end
end
