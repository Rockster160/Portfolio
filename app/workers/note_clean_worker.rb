# Writes a readable version of a note he typed, once on the notes that land
# from a conversation - and again on the one being read when he asks for it.
#
# No chip while it runs, unlike the transcript passes. That is one GPT call on
# a couple of kilobytes and it is done in a second or two; a chip on the strip
# over Buddy would appear and go before anyone read it, and a chip nobody can
# read is attention spent for nothing.
#
# Takes an id rather than a record so a retry re-reads current state, and gives
# up quietly on anything since deleted. `again` is the press on the page:
# `Clean.call` refuses a note it has already done unless it is asked twice, and
# a second pass OVERWRITES a version he edited by hand - which is why nothing
# passes `again` except that press.
class NoteCleanWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  def perform(note_id, again=false)
    note = JobNote.find_by(id: note_id)
    return if note.nil?

    report(note, Notes::Clean.call(note, again: again))
  end

  private

  def report(note, result)
    Rails.logger.info(
      "[NoteClean] ##{note.id} #{result.ok ? "written" : "skipped"} " \
      "chars=#{result.chars} error=#{result.error}",
    )
  end
end
