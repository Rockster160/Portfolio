class AddRepoToFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    add_column :feature_builds, :repo, :string, null: false, default: "Rockster160/Portfolio"
    add_column :feature_builds, :pulled_at, :datetime
  end
end
