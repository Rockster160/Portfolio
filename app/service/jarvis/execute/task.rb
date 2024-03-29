class Jarvis::Execute::Task < Jarvis::Execute::Executor
  def input_data
    jil.data
  end

  def print
    jil.ctx[:msg] << ::Jarvis::Execute::Raw.str(evalargs)
  end

  def comment
    # No-op. Just shows the text
  end

  def command
    Jarvis.command(jil.task.user, evalargs)
  end

  def request
    http_method, url, headers, params = evalargs
    json = ProxyRequest.execute(
      method:  http_method,
      url:     url,
      headers: headers.to_h,
      params:  params.to_h,
    )
    if json.is_a?(Hash)
      json
    else
      { data: json.body }
    end
  end

  def exit
    jil.ctx[:exit] = true
    nil
  end

  def return_data
    (jil.ctx[:return] = evalargs).tap { jil.ctx[:exit] = true }
  end

  def fail
    raise NotImplementedError
  end

  def run
    name, timestamp = evalargs
    run_task = jil.task.user.jarvis_tasks.anyfind(name)

    if timestamp
      # TODO: The ctx[:i] will not be passed back- this can be used to bypass block limitations
      # Not sure how to work around this...
      # At least pass `i` through, so the scheduled job will continue off of this one.
      # * This prevents infinity, but can still be used to bypass the 1k limit
      jid = Jarvis::Schedule.schedule(
        scheduled_time: timestamp,
        user_id: jil.task.user.id,
        words: "Run #{run_task.name}",
        type: :command,
        # vars: { i: jil.ctx[:i] }
      ).first
      ::BroadcastUpcomingWorker.perform_async

      jid
    else
      msg = ::Jarvis::Execute.call(run_task, { ctx: { i: jil.ctx[:i] } })
      jil.ctx[:i] = run_task.last_ctx[:i]

      msg
    end
  end

  def get
    task_id = evalargs
    task = jil.task.user.jarvis_tasks.anyfind(task_id)

    task.serialize
  end

  def enable
    task_id, bool = evalargs
    task = jil.task.user.jarvis_tasks.anyfind(task_id)

    task.update(enabled: !!bool)
  end

  def find
    raise NotImplementedError
  end

  def schedule
    cmd, timestamp, data = evalargs

    # TODO: The ctx[:i] will not be passed- this can be used to bypass block limitations
    # Not sure how to work around this...
    # Maybe somehow pass a back reference to the id,
    #   and use that to get the count for the new task as well as update the old task
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

  def email
    raise NotImplementedError
  end

  def sms
    raise NotImplementedError
  end

  def ws
    channel, data = evalargs
    SocketChannel.send_to(jil.task.user, channel, data)
  end
end
