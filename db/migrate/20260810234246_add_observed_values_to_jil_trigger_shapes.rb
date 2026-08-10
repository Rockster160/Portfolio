class AddObservedValuesToJilTriggerShapes < ActiveRecord::Migration[7.1]
  def change
    add_column(:jil_trigger_shapes, :observed_values, :jsonb, null: false, default: {})
  end
end
