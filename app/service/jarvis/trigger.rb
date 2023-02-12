class Jarvis::Trigger < Jarvis::Action
  def attempt
    task = @user.jarvis_tasks.find_by("name ILIKE ?", @msg)
    return unless task

    ::Jarvis::Execute.call(task).then { |res|
      res = Array.wrap(res).select { |item| item.present? && item != "Success" }
      res.first || Jarvis::Text.affirmative
    }
  end
end
