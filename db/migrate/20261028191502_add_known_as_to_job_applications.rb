class AddKnownAsToJobApplications < ActiveRecord::Migration[7.1]
  def change
    add_column :job_applications, :known_as, :jsonb, default: [], null: false
  end
end
