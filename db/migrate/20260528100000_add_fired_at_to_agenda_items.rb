class AddFiredAtToAgendaItems < ActiveRecord::Migration[7.1]
  # Trigger firing previously stamped `completed_at` to dedupe — but that
  # also auto-checked the user-facing checkbox, which contradicts the rule
  # that the checkbox is only ever toggled by an explicit click.
  # `fired_at` decouples "this trigger ran" from "the user marked it done."
  def change
    add_column :agenda_items, :fired_at, :datetime
    add_index :agenda_items, :fired_at, where: "fired_at IS NOT NULL"
  end
end
