class AddQuestionToFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    change_table(:feature_builds, bulk: true) { |t|
      t.text :question
      t.datetime :asked_at
    }
  end
end
