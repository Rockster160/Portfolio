class AddDebriefToJobTranscripts < ActiveRecord::Migration[7.1]
  def change
    add_column :job_transcripts, :debrief, :jsonb, null: false, default: {}
    add_column :job_transcripts, :debriefed_at, :datetime
  end
end
