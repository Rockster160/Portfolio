class Jarvis::Trigger < Jarvis::Action
  def attempt
    ::Jarvis::MatchTask.match_run(@user, @msg.gsub(/^\s*run:?\s+/i, ""))
  end
end
