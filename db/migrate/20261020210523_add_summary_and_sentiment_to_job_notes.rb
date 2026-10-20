class AddSummaryAndSentimentToJobNotes < ActiveRecord::Migration[7.1]
  # `summary` is the one line the timeline shows with the beat collapsed. The
  # model already writes one for every mail it files and it was being thrown
  # away, so the column is mostly a matter of keeping what is already said.
  #
  # `did_well` and `liked_them` are his, 0-10, and only on a beat that was a
  # real conversation. Nullable because most beats are mail and a mail has no
  # opinion in it - and because a rating nobody gave must read as unrated
  # rather than as a zero, which would drag an average down for every call he
  # never got round to scoring.
  def change
    add_column :job_notes, :summary, :string
    add_column :job_notes, :did_well, :integer
    add_column :job_notes, :liked_them, :integer
  end
end
