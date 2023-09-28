class Jarvis::Trigger < Jarvis::Action
  def attempt
    task = ::Jarvis::MatchTask.match_run(@user, @msg.gsub(/^\s*run:?\s+/i, ""))
    task&.then { |t| "Ran #{t.name}" }
  end
end
