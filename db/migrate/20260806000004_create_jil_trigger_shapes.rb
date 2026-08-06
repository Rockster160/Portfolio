class CreateJilTriggerShapes < ActiveRecord::Migration[7.1]
  # What a trigger payload actually looks like when it fires.
  #
  # Writing a custom watch means naming a field on a payload nobody has ever
  # seen: `remind_when` accepts a listener like `item:section:Garage`, and
  # whether `section` is even a key on an `item` payload is a fact that existed
  # only inside ListItem#jil_serialize. So watches got written against invented
  # field names, matched nothing, and failed silently — a watch that never fires
  # looks identical to one whose condition hasn't happened yet.
  #
  # The bus already carries the answer past us on every single trigger. This
  # just writes down what went by.
  #
  # One row per user per scope, holding the observed key paths and a redacted
  # sample. Writes are rate-limited hard (see Buddy::TriggerShapes) because
  # Jil::Executor.trigger is synchronous on the request thread and some of these
  # scopes fire hundreds of times a day.
  def change
    create_table :jil_trigger_shapes do |t|
      t.belongs_to :user, index: false, null: false
      t.text :scope, null: false
      # Flattened dotted key paths — ["id", "name", "list.name", "section.name"].
      t.jsonb :keys, default: [], null: false
      # One payload's worth of shapes-of-values, never the values themselves.
      t.jsonb :sample, default: {}, null: false
      t.integer :seen_count, default: 0, null: false
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :jil_trigger_shapes, [:user_id, :scope], unique: true
  end
end
