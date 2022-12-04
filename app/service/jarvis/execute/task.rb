class Jarvis::Execute::Task < Jarvis::Execute::Executor
  def input_data
    raise NotImplementedError
  end

  def print
    jil.ctx[:msg] << eval_block(args)
  end

  def comment
    # No-op. Just shows the text
  end

  def command
    jil.ctx[:msg] << Jarvis.command(jil.task.user, eval_block(args))
  end

  def exit
    jil.ctx[:exit] = true
    eval_block(args)
  end

  def fail
    raise NotImplementedError
  end

  def run
    raise NotImplementedError
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
