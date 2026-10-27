class AddTermsToJobApplications < ActiveRecord::Migration[7.1]
  def change
    add_column :job_applications, :location, :string
    add_column :job_applications, :pay, :string
  end
end
