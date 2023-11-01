class Jarvis::Trigger < Jarvis::Action
  def attempt
    task = ::Jarvis::MatchTask.match_run(@user, @msg.gsub(/^\s*run:?\s+/i, ""), return_as: :task)
    task&.then { |t|
      t.last_result.gsub(/^(true|false|Success|\d+)$/i, "").gsub(/\n+/, "\n").strip.presence || "Ran #{t.name}"
    }
  end
end
