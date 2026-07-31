class AddListenerToBuddyWatches < ActiveRecord::Migration[7.1]
  # A Jil listener string, for watches Buddy writes itself rather than picking
  # from the named triggers. When present it replaces the `match` hash: matching
  # runs through Jil::ListenerMatch, the same code that decides whether a Jil
  # task fires, so the syntax and the behaviour are identical.
  def change
    add_column :buddy_watches, :listener, :string
  end
end
