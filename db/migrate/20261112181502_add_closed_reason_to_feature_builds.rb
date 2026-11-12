class AddClosedReasonToFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    add_column :feature_builds, :closed_reason, :text
  end
end
