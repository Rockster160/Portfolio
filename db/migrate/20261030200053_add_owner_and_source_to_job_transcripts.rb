class AddOwnerAndSourceToJobTranscripts < ActiveRecord::Migration[7.1]
  def change
    add_reference :job_transcripts, :user, foreign_key: true, index: true
    add_column :job_transcripts, :source, :jsonb, null: false, default: {}
    change_column_null :job_transcripts, :job_application_id, true
  end
end
