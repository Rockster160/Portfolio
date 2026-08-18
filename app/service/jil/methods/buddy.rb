class Jil::Methods::Buddy < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :String)
  end

  # [Buddy]
  #   #say(Text)::Boolean
  #   #sayEvent("Event" Numeric|Hash|AgendaItem BR "Message" String)::Numeric
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

  # The same fixed message, but delivered to whoever the EVENT belongs to
  # rather than to whoever's task is running. Returns how many people it
  # reached, so a task can tell "nobody uses Buddy" from "sent".
  #
  # The travel alerts are the reason this exists. They're computed by Rocco's
  # tasks — the car is his, the address book is his — but the event might be
  # on Chelsea's calendar, and "leave by 5:30" is no use to the person not
  # going. `Agenda#subject_users` is the whose-day-is-it rule; a personal
  # calendar answers with its owner however widely it's shared, a joint one
  # answers with everybody.
  #
  # Nobody gets a companion spun up for them by a notification: the audience
  # is narrowed to people who already have a Buddy conversation, same gate as
  # AgendaNotifyOthersWorker. An event that can't be resolved reaches nobody
  # and says so with a 0 — better a missing message than one sent to a guess.
  def sayEvent(event, message)
    text = message.to_s.strip
    item = resolve_item(event)
    return 0 if text.empty? || item.blank?

    users = audience(item).to_a
    users.each { |user| deliver_to(user, text) }
    users.size
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
    deliver_to(recipient, text, files: files, push_title: push_title)
  end

  def deliver_to(user, text, files: [], push_title: nil)
    ::Buddy::CompanionDelivery.deliver_plain(
      user:         user,
      conversation: ::Buddy::CompanionRelay.conversation_for(user),
      text:         text,
      files:        files,
      metadata:     { kind: :buddy, source: :jil },
      push_title:   push_title || text,
    )
  end

  # An id, the serialized hash an agenda trigger fires with, or the record
  # itself — the three shapes a Jil task can be holding. Scoped to the
  # executing user, so a task can only speak about events it can already see.
  def resolve_item(value)
    return value if value.is_a?(::AgendaItem)

    id = (value.is_a?(::Hash) ? (value[:id] || value["id"]) : value)
    return nil if id.blank?

    ::AgendaItem.locate_for_user(id, @jil.user)
  end

  def audience(item)
    item.agenda.subject_users.where(id: ::ByteConversation.where(mode: :buddy).select(:user_id))
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
