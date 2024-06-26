class Jarvis::Trigger < Jarvis::Action
  def attempt
    user_tasks = @user.jarvis_tasks.enabled
    text = @msg.gsub(/^\s*run:?\s+/i)
    ran_tasks = []

    if text.match?(/^(\w+-)+\w+$/i)
      begin
        task = user_tasks.anyfind(text)
        task.execute
        ran_tasks << task
      rescue ActiveRecord::RecordNotFound
      end
    end

    ran_tasks += Jarvis.trigger_events(@user, :tell, text)

    ran_tasks.last&.then { |t|
      t.return_val.presence.is_a?(String) ? t.return_val : "Ran #{t.name}"
    }
  end
end
