class AddAnnouncedAtToJobTranscripts < ActiveRecord::Migration[7.1]
  def change
    add_column :job_transcripts, :announced_at, :datetime
  end
end
