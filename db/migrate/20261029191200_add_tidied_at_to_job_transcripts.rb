class AddTidiedAtToJobTranscripts < ActiveRecord::Migration[7.1]
  def change
    add_column :job_transcripts, :tidied_at, :datetime
  end
end
