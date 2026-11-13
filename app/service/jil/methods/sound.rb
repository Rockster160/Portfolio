class Jil::Methods::Sound < Jil::Methods::Base
  # [Sound]
  #   #new(content(SoundNote [SoundNote.beep SoundNote.rest]))
  #   .duration::Numeric // milliseconds, start to finish
  #
  # A Sound is the notes it plays in order, in the shape the browser's `beeps`
  # takes - see Buddy::BoardSound. Playing one is Buddy.sound, or a yell's
  # `sound`.

  def cast(value)
    ::Buddy::BoardSound.notes(value)
  end

  def init(line)
    cast(evalargs(line.args).first)
  end

  def duration(notes)
    cast(notes).sum(&:first)
  end
end
