# Per-person Byte display preferences.
#
# Deliberately a bag rather than a `byte_font_scale` column: font size is the
# first of these to be asked for, not the last, and a jsonb means the next one
# is a reader method instead of a migration. Matches how buddy_features and
# chore_notify_prefs already work on this table.
class AddBytePrefsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :byte_prefs, :jsonb, null: false, default: {}
  end
end
