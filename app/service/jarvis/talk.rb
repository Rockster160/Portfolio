class Jarvis::Talk < Jarvis::Action
  def attempt
    # if combine.match?(/\b(good morning|afternoon|evening)/)
    #   Find the weather, summarize events (ignore morning work meetings?)
    if @msg.match?(/\b(hello|hey|hi|you there|you up|good evening|good night|good morning|afternoon)/i)
      Jarvis::Text.im_here
    elsif @msg.match?(/\b(thank)/i)
      Jarvis::Text.appreciate
    else
      "I don't know how to #{Jarvis::Text.rephrase(@msg)}, sir."
    end
    # complete ["Check", "Will do, sir.", "As you wish.", "Yes, sir."]
  end
end
