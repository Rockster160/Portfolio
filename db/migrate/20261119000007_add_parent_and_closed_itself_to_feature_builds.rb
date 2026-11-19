class AddParentAndClosedItselfToFeatureBuilds < ActiveRecord::Migration[7.1]
  def change
    add_reference :feature_builds, :parent, foreign_key: { to_table: :feature_builds, on_delete: :nullify }
    add_column :feature_builds, :closed_itself, :boolean, null: false, default: false
  end
end
