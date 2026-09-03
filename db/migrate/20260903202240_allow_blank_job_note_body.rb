class AllowBlankJobNoteBody < ActiveRecord::Migration[7.1]
  # A note tagged `interview` on a date is a complete thought — the tag says
  # what happened and the timestamp says when. Requiring words as well meant
  # anything without them had to invent some, and "Applied." next to a chip
  # already reading APPLIED is the same fact printed twice.
  #
  # An untagged note still needs a body; that one IS its words. The model
  # carries that half (see JobNote).
  def change
    change_column_null :job_notes, :body, true
  end
end
