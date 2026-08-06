class CreateRecordLinks < ActiveRecord::Migration[7.1]
  # "This chore and this event are the same thing." "Completing this chore ticks
  # the item off the list."
  #
  # These connections already existed, as Ruby Hash literals inside Jil function
  # tasks 361, 364 and 381, read by five listener tasks. That worked, and cost
  # what hand-maintained code costs: adding a pairing meant editing Jil in a web
  # editor, and the direction of each connection was implicit in which listener
  # tasks happened to exist.
  #
  # Three things about the shape matter, and none is obvious:
  #
  # 1. THE CASCADE ONLY RUNS DOWNHILL.
  #
  #      event  ->  chore  ->  agenda  ->  list_item
  #
  #    A link's source must outrank its target, and the model enforces it. That
  #    single rule is what makes this comprehensible: logging an event completes
  #    the chore, completing the chore ticks off the agenda item and the list
  #    item, and nothing ever runs back up. Completing a chore does NOT write an
  #    event; checking something off a list does NOT touch the chore. Both of
  #    those used to happen, and between them they're why the old pair of rules
  #    could chase each other in a circle.
  #
  #    `reverse` is the escape hatch for the day a specific pairing genuinely
  #    needs to run uphill. Nothing sets it today and the manager doesn't offer
  #    it; it exists so the answer to "can we ever?" is yes.
  #
  # 2. AN ENDPOINT IS A NAME, NOT A FOREIGN KEY. An ActionEvent isn't a durable
  #    thing you can point at — every logged coffee is a new row — so the
  #    pairing is with events *called* "Coffee". The old maps were keyed on
  #    names for the same reason. The two ends are independent, which is the
  #    point: chore "Focus" pairs with event "D-Amphetamine", and chore "Check
  #    Softener Salt" with list item "Check Salt".
  #
  # 3. THE SOURCE SIDE MATCHES LOOSELY WHEN IT HAS TO. `source_name_match` and
  #    `source_scope_match` are exactly / starts_with / contains. Exact is right
  #    for a chore, whose name is a record. It is wrong for a medication logged
  #    with its dosage: the Cymbalta pairing hangs on the notes string
  #    "Duloxetine Hydrochlride 20mg", typo and all, and any variation in how
  #    it's typed misses in silence.
  def change
    create_table :record_links do |t|
      t.belongs_to :user, index: false, null: false

      t.integer :source_kind, null: false
      t.text :source_name, null: false
      # Narrows the name where a name alone is ambiguous: an event's notes
      # value, which is the only thing separating "Fae / Litter" from
      # "Fae / Food".
      t.text :source_scope
      t.integer :source_name_match, default: 0, null: false
      t.integer :source_scope_match, default: 0, null: false

      t.integer :target_kind, null: false
      t.text :target_name, null: false
      # Which list, for a list item. Not a match rule — the target is looked up
      # or created, never matched.
      t.text :target_scope

      # Several people in the house do this one, so ask who rather than
      # crediting whoever happened to log it. Only meaningful on event -> chore.
      t.boolean :ask_who, default: false, null: false
      # Run this one uphill. See (1) above.
      t.boolean :reverse, default: false, null: false
      t.boolean :enabled, default: true, null: false
      # Free text for whoever reads this in a year wondering why it exists.
      t.text :note

      t.timestamps
    end

    add_index :record_links, [:user_id, :source_kind, :source_name], name: :index_record_links_on_source
    add_index :record_links, [:user_id, :target_kind, :target_name], name: :index_record_links_on_target
    add_index :record_links,
      "user_id, source_kind, lower(source_name), coalesce(lower(source_scope), ''), " \
      "target_kind, lower(target_name), coalesce(lower(target_scope), '')",
      unique: true,
      name:   :index_record_links_uniqueness
  end
end
