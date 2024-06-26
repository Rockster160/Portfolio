class Jarvis::Trigger < Jarvis::Action
  def attempt
    text = @msg.gsub(/^\s*run:?\s+/i, "")
    ran_tasks = []

    if text.match?(/^(\w+-)+\w+$/i)
      begin
        task = @user.jarvis_tasks.enabled.anyfind(text)
        task.execute
        ran_tasks << task
      rescue ActiveRecord::RecordNotFound
      end
    end

    ran_tasks += Jarvis.trigger_events(@user, :tell, text)
    ran_tasks.find { |t| break t.return_val if t.return_val.present? } || ran_tasks.find { |t| break "Ran #{t.name}" if t.name.present? }
  end
end
