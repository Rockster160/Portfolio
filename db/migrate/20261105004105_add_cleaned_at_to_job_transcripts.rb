class AddCleanedAtToJobTranscripts < ActiveRecord::Migration[7.1]
  def change
    add_column :job_transcripts, :cleaned_at, :datetime
  end
end
