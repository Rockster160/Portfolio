class AddRubricToJobApplications < ActiveRecord::Migration[7.1]
  def change
    add_column :job_applications, :rubric, :jsonb, default: [], null: false
  end
end
