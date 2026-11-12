class AddMergeQueueToFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    change_table(:feature_builds, bulk: true) { |t|
      t.integer :queue_position
      t.datetime :approved_at
      t.datetime :landing_at
      t.boolean :held, null: false, default: false
    }
  end
end
