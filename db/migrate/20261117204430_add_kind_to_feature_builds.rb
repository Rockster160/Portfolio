class AddKindToFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    add_column :feature_builds, :kind, :integer, default: 0, null: false
  end
end
