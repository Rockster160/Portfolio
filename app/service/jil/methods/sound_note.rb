class Jil::Methods::SoundNote < Jil::Methods::Base
  # *[SoundNote]
  #   #beep(Numeric(400):"Milliseconds" Numeric(440):"Hertz" Slider(0.9):"Volume" ["sine" "square" "sawtooth" "triangle"])
  #   #rest(Numeric(200):"Milliseconds")
  #
  # One line of a Sound: the same four things `beep` takes, or a silence.

  def cast(value)
    ::Buddy::BoardSound.note(value)
  end

  def beep(duration, frequency, volume, wave)
    [duration, frequency, volume, wave]
  end

  def rest(duration)
    [duration, 0, 0, nil]
  end
end
