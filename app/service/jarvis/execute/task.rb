class Jarvis::Execute::Task < Jarvis::Execute::Executor
  def input_data
    jil.data
  end

  def print
    jil.ctx[:msg] << evalargs
  end

  def comment
    # No-op. Just shows the text
  end

  def command
    Jarvis.command(jil.task.user, evalargs)
  end

  def exit
    jil.ctx[:exit] = true
    evalargs if args
  end

  def fail
    raise NotImplementedError
  end

  def run
    name, timestamp = evalargs
    run_task = jil.task.user.jarvis_tasks.find_by!(name: name)

    if timestamp
      # TODO: The ctx[:i] will not be passed- this can be used to bypass block limitations
      # Not sure how to work around this...
      jid = Jarvis::Schedule.schedule(
        scheduled_time: timestamp,
        user_id: jil.task.user.id,
        words: run_task.name,
        type: :command,
      ).first
      # jil.ctx[:i] = run_task.last_ctx[:i]
      ::BroadcastUpcomingWorker.perform_async

      jid
    else
      msg = ::Jarvis::Execute.call(run_task, { ctx: { i: jil.ctx[:i] } })
      jil.ctx[:i] = run_task.last_ctx[:i]

      msg
    end
  end

  def find
    raise NotImplementedError
  end

  def schedule
    cmd, timestamp = evalargs

    # TODO: The ctx[:i] will not be passed- this can be used to bypass block limitations
    # Not sure how to work around this...
    jid = Jarvis::Schedule.schedule(
      scheduled_time: timestamp,
      user_id: jil.task.user.id,
      words: cmd,
      type: :command,
    ).first
    # jil.ctx[:i] = run_task.last_ctx[:i]
    ::BroadcastUpcomingWorker.perform_async

    jid
  end

  def request
    raise NotImplementedError
  end

  def email
    raise NotImplementedError
  end

  def sms
    raise NotImplementedError
  end

  def ws
    raise NotImplementedError
  end
end
