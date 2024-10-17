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
      SlackNotifier.notify("Attempted to run JarvisTask async: (JarvisTask[#{run_task.id}])")

      0
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
    SlackNotifier.notify("Attempted to run JarvisTask[#{jil.task.id}] async: ('#{cmd}')")
    0
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
