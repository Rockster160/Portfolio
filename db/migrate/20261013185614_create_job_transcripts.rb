class CreateJobTranscripts < ActiveRecord::Migration[7.1]
  def change
    create_table :job_transcripts do |t|
      t.references :job_application, null: false, foreign_key: true
      # The beat it belongs to, when there is one. Optional because a recording
      # often lands before anybody has written the note for it, and refusing
      # the upload until the timeline is tidy is the wrong order to work in.
      t.references :job_note, null: true, foreign_key: true
      t.string :title
      t.datetime :occurred_at

      # WHO EACH LABEL TURNED OUT TO BE. The recorder names them `Speaker 1`
      # and `Unknown`, which is not a person, so the mapping from a label to a
      # name is something only he can supply.
      t.jsonb :speakers, null: false, default: {}
      # The conversation itself: one entry per turn, each with the label it was
      # transcribed under, the label it has been corrected to, and when it was
      # said. Kept as rows rather than re-parsed from the file on every read -
      # a turn's speaker is editable, and an edit has to survive.
      t.jsonb :turns, null: false, default: []

      t.timestamps
    end
  end
end
