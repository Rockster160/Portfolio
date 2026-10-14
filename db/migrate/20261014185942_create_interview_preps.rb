class CreateInterviewPreps < ActiveRecord::Migration[7.1]
  def change
    create_table :interview_preps do |t|
      t.references :job_application, null: false, foreign_key: true
      # The booking it was written for. Optional because a brief can be asked
      # for by hand when no row has been put on the calendar yet, and because
      # the event may be gone by the time anybody reads the brief back.
      t.references :agenda_item, null: true, foreign_key: true
      # The thread the research actually happened in, so a brief that says
      # something wrong can be read back against every tool call that produced
      # it. Nullified rather than cascaded: the transcript is housekeeping and
      # the brief is the thing worth keeping.
      t.references :byte_message, null: true, foreign_key: { on_delete: :nullify }

      t.string :title
      t.text :body

      # What kind of conversation it is written for - a recruiter call wants
      # company facts and a technical screen wants a stack to brush up on, and
      # the brief says which it decided on. Stored so the page can say it in
      # the heading without re-reading the prose.
      t.string :kind

      # When the interview is. Not derived from the agenda item: the row can
      # move or be deleted, and "what was this brief for" has to survive that.
      t.datetime :interview_at

      t.timestamps
    end
  end
end
