class Jarvis::Execute::Task < Jarvis::Execute::Executor
  def input_data
    jil.data
  end

  def print
    jil.ctx[:msg] << ::Jarvis::Execute::Cast.cast(evalargs.first, :str, force: true, jil: jil)
  end

  def comment
    # No-op. Just shows the text
  end

  def command
    Jarvis.command(jil.task.user, evalargs.first)
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

  def prompt
    user = jil.task.user
    question, options, data, task_id = evalargs
    prompt = user.prompts.create(
      question:    question,
      options:     options,
      params:      data,
      task:        user.jarvis_tasks.anyfind(task_id),
      # answer_type: "",
    )
    jil.ctx[:msg] += prompt.errors.full_messages unless prompt.persisted?
    pushed = WebPushNotifications.send_to(user, {
      title: question,
      url: Rails.application.routes.url_helpers.jil_prompt_url(prompt)
    })

    pushed != "Push success"
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

  def find
    raise NotImplementedError
  end

  def schedule
    cmd, timestamp, data = evalargs

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

  def email
    raise NotImplementedError
  end

  def sms
    raise NotImplementedError
  end

  def ws
    channel, data = evalargs
    # Broadcast.to(jil.task.user, channel, data)
    SocketChannel.send_to(
      jil.task.user,
      channel,
      data,
    )
  end
end
