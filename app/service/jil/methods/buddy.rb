class Jil::Methods::Buddy < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :String)
  end

  # [Buddy]
  #   #say(Text)::Boolean
  #   #prompt(Text)::Boolean
  #   #photo("Image" String BR "Caption" String)::Boolean

  # Byte/Moss says the text verbatim — a fixed inbound message dropped into the
  # user's Buddy conversation, plus a push. Use when the wording is yours and
  # should land exactly as written.
  def say(message)
    text = message.to_s.strip
    return false if text.empty?

    deliver(text)
    true
  end

  # Byte/Moss puts a picture in front of them — a camera frame, above all.
  #
  # `image` is base64, which is how HASS's `camera_frame` script hands a frame
  # back (`image_b64`). Jil can't carry bytes and doesn't need to: the string
  # comes out of one HTTP response and goes straight into a blob.
  #
  # `caption` is optional — an image on its own is a real message here, same as
  # it is from the composer. The push still needs words, so a captionless one
  # says something anyway rather than buzzing a blank notification.
  #
  # Returns false rather than raising when the image doesn't decode, so a task
  # can say "I couldn't get a frame" instead of dying halfway through.
  def photo(image, caption=nil)
    images = ::ByteImageIntake.from_base64(image, filename: "camera.jpg")
    return false unless images.ok?

    text = caption.to_s.strip
    deliver(text, files: images.blobs, push_title: text.presence || "📷 New photo")
    true
  end

  # Re-dispatches a fresh in-character Buddy turn seeded by the text, so the
  # reply reads like Byte/Moss talking rather than a canned string. `buddy_trigger`
  # is what marks the resulting reply self-initiated (see Buddy::GPT::Turn), so it
  # pushes even when the app is foregrounded.
  def prompt(seed)
    text = seed.to_s.strip
    return false if text.empty?

    user = recipient
    ::Buddy::CompanionDelivery.deliver_prompt(
      user:         user,
      conversation: ::Buddy::CompanionRelay.conversation_for(user),
      seed:         text,
      metadata:     { kind: :buddy_trigger, hidden: true, source: :jil },
    )
    true
  end

  private

  def deliver(text, files: [], push_title: nil)
    user = recipient
    ::Buddy::CompanionDelivery.deliver_plain(
      user:         user,
      conversation: ::Buddy::CompanionRelay.conversation_for(user),
      text:         text,
      files:        files,
      metadata:     { kind: :buddy, source: :jil },
      push_title:   push_title || text,
    )
  end

  # Who the message is actually FOR, which is not always whose task this is.
  #
  # A SHARED task runs as its owner — `@jil.user` is Rocco even when Chelsea is
  # the one who asked, and that's deliberate: running as the owner is how the
  # task reaches his HASS credentials at all (Task#execute runs as `task.user`).
  # Delivering to `@jil.user` would then answer her question in his thread and
  # leave hers empty, which is a picture of her front door arriving on somebody
  # else's phone.
  #
  # The execution already knows who asked. `auth_type: :buddy` carries the
  # acting user's id for exactly this — see the enum note on Execution.
  #
  # Anything NOT fired through Buddy — cron, a trigger, a `tell:` — has no asker
  # and the owner is the right answer.
  def recipient
    execution = @jil.execution
    return @jil.user unless execution&.auth_type.to_s == "buddy"

    ::User.find_by(id: execution.auth_type_id) || @jil.user
  end
end
