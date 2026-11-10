class AddFeatureRequestAndPlannedAtToFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    add_reference :feature_builds, :feature_request, foreign_key: { on_delete: :nullify }
    add_column :feature_builds, :planned_at, :datetime
  end
end
