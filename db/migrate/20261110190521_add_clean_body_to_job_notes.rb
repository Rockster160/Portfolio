class AddCleanBodyToJobNotes < ActiveRecord::Migration[7.1]
  def change
    change_table(:job_notes, bulk: true) { |t|
      t.text :clean_body
      t.datetime :cleaned_at
    }
  end
end
