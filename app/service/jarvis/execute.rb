class Jarvis::Execute
  def self.call(task)
    task.update(last_trigger: Time.current)
    # Do the things
  end
end
