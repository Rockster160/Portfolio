class RenameSprigThemeToBloom < ActiveRecord::Migration[7.1]
  # The "sprig" companion is now "bloom" — key, class, files and assets all
  # renamed. Buddy::Companion.find falls back to the default pet for an unknown
  # key, so any board or thread still storing the old value would silently show
  # Byte until this runs. Data-only; reversible.
  def up
    execute("UPDATE byte_conversations SET buddy_theme = 'bloom' WHERE buddy_theme = 'sprig'")
  end

  def down
    execute("UPDATE byte_conversations SET buddy_theme = 'sprig' WHERE buddy_theme = 'bloom'")
  end
end
