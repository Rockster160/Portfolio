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
    name = evalargs

    run_task = jil.task.user.jarvis_tasks.find_by("name ILIKE ?", evalargs)
    msg = ::Jarvis::Execute.call(run_task, { ctx: { i: jil.ctx[:i] } })
    jil.ctx[:i] = run_task.last_ctx[:i]

    msg
  end

  def find
    raise NotImplementedError
  end

  def schedule
    raise NotImplementedError
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
