class AddMergeShaToFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    change_table(:feature_builds, bulk: true) { |t|
      t.string :merge_sha
      t.datetime :deployed_at
    }
  end
end
