class Jil::Methods::Interview < Jil::Methods::Base
  # Starts the pre-interview brief: a read-only Claude session on the desk Mac
  # that researches the company, works out what the conversation is, and writes
  # up what to go over before it starts. See ByteInterviewPrep for the whole
  # chain and for what the session is allowed to do.
  #
  # It RETURNS IMMEDIATELY. The session takes minutes and nothing is said while
  # it runs; the brief arrives as its own message carrying a link once it is
  # filed. A task calling this is a starter pistol, not a step that waits.
  #
  # The agenda item is the argument because that is what the -60 minute trigger
  # carries: `Global.trigger_for` keys on the event, and the fired payload is
  # the trigger's own data, so the task that schedules it puts the id in there.
  # Which application it belongs to is read off the first line of the event's
  # notes, where every row a job beat writes puts the link.
  #
  # Owner-only. The schema hides it from everybody else (`[Interview]@me`) and
  # this is the part that actually refuses, because code reaches the executor
  # by routes that never open the editor.
  #
  # The same two checks [Mac] makes, and for the same reason: the task being
  # his is not enough, because a SHARED task runs as its owner - so anybody
  # else pressing Run on it, or asking their companion to fire it, would arrive
  # here as him. See `Jil::Methods::Base#owned_and_run_by_me?`.

  def cast(value)
    @jil.cast(value, :Hash)
  end

  # [Interview]
  #   #prep(Numeric:"Agenda Item")::Hash

  # `{ started:, state: }` rather than a bare boolean, so a task can say which
  # branch it took without the executor having to guess: `already_prepped`,
  # `not_an_interview` and `no_event` are all perfectly ordinary answers here -
  # the listener matches any event with "interview" in the title, and one
  # interview puts TWO rows on the calendar, of which only ours carries the
  # link that names the application.
  def prep(item_id)
    return { started: false, state: "not authorized" } unless permitted?

    state = ::ByteInterviewPrep.dispatch(@jil.user, @jil.cast(item_id, :Numeric).to_i)

    { started: state == :sent, state: state.to_s }
  rescue StandardError => e
    ::PrettyLogger.error("[JIL INTERVIEW] prep #{item_id}: #{e.class}: #{e.message}")
    { started: false, state: e.message }
  end

  private

  def permitted?
    owned_and_run_by_me?
  end
end
