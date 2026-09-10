class Jil::Methods::Buddy < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :String)
  end

  # [Buddy]
  #   #say(Text)::Boolean
  #   #sayEvent("Event" Numeric|Hash|AgendaItem BR "Message" String)::Numeric
  #   #prompt(Text)::Boolean
  #   #photo("Image" String BR "Caption" String)::Boolean
  #   #checklist("List" String BR "Message" Text)::Numeric
  #   #alert("Key" String BR "Message" Text BR "Who" String)::Boolean
  #   #resolve("Key" String BR "Message" Text BR "Who" String)::Boolean
  #   #rotate("Key" String BR "Label" String BR Numeric ["seconds" "minutes" "hours"] BR "Again" String BR "Done adds" String " to " String)::Boolean

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

  # The named list, put in front of them as a row of empty checkboxes - one per
  # item - under `message`. Ticking one takes that item off the list, the same
  # act as checking it off in the app; unticking puts it back.
  #
  # Returns how many boxes went up, so a task can tell "there was nothing left
  # to do" from "sent". An empty list posts NOTHING and answers 0: a bedtime
  # nudge listing no items is a buzz about nothing, and the caller is better
  # placed to decide whether that deserves words of its own.
  def checklist(list_name, message)
    list = ::List.by_name_for_user(list_name.to_s, @jil.user)
    text = message.to_s.strip
    return 0 if list.nil? || text.empty?

    ::Buddy::ListChecklist.post!(user: recipient, list: list, text: text)
  end

  # Something that needs DOING, held open until it's dealt with.
  #
  # Everything else here is news - it happened, it's said, it's over. A
  # condition isn't like that: "the laundry gate is open" goes on being true
  # until somebody closes the gate, and saying it again an hour later doesn't
  # help. This posts one message and keeps it: calling it again on the same key
  # rewrites that same message rather than adding another notification for
  # something already on screen, and counts the occurrence on it.
  #
  # `key` is the identity of the condition and is entirely yours. It is the only
  # coupling between the thing that NOTICES and the thing that CLEARS, which are
  # rarely the same sensor or even the same day.
  #
  # `who` is who it is FOR, and blank is whoever's task this is - nearly always
  # right, since a condition is usually noticed by somebody's own automation.
  # A name reaches that person instead; "house" reaches everyone. See
  # `recipients_for`.
  #
  # Returns false when it reached nobody - no key, no words, no companion thread
  # yet, or a name nobody in the house goes by - so a task can tell that from a
  # message that landed.
  def alert(key, message, who=nil)
    delivered = recipients_for(who).count { |user|
      ::Buddy::Alerts.raise!(user: user, key: key, body: message).present?
    }
    delivered.positive?
  end

  # It's been dealt with. The message `alert` left in the thread is rewritten
  # where it stands, so the thing that was outstanding now reads as handled -
  # no second message, and nothing left saying a condition that has passed.
  #
  # `message` is what it should say now; leave it blank and it keeps its own
  # words and simply stops reading as outstanding.
  #
  # `who` has to match whoever the alert was raised for, and the easy way to get
  # that right is to pass the same thing both times.
  #
  # Returns false when nothing was open under that key for anybody, which is how
  # a check that runs on a schedule tells "I just cleared something" from "it was
  # already fine" without keeping track itself.
  def resolve(key, message, who=nil)
    cleared = recipients_for(who).count { |user|
      ::Buddy::Alerts.resolve!(user: user, key: key, body: message).present?
    }
    cleared.positive?
  end

  # The words that mean the whole house rather than one person, and the ones that
  # mean whoever the task already belongs to. Spelled out rather than
  # pattern-matched because these are typed into a task once, and a near miss
  # has to fail loudly instead of quietly meaning something else.
  HOUSEHOLD = %w[house household home everyone everybody all].freeze
  ME        = %w[me myself i owner].freeze

  # Same unit set the schema offers. Anything else is a typo rather than a
  # duration, and a rotation silently landing in seconds when "minutes" was
  # meant is 75 seconds of laundry.
  ROTATE_UNITS = { "seconds" => 1, "minutes" => 60, "hours" => 3600 }.freeze

  # A visible countdown that comes back and ASKS whether to go round again —
  # the laundry, above all. `key` is the loop's identity: calling this again
  # while one is live restarts it and answers any question already on screen,
  # which is what makes a physical button press mean "I rotated it".
  #
  # `item`/`list` are the follow-up left behind when they answer Done ("Fold
  # Laundry" onto TODO); leave either blank and Done just ends the loop.
  # Returns false when there's nowhere to put the countdown — nobody's Buddy
  # thread exists yet — so a task can tell that from a timer that ran.
  def rotate(key, label, number, interval, again, item, list)
    seconds = duration_seconds(number, interval)
    return false if key.to_s.strip.empty? || seconds < 1

    ::Buddy::RotationTimer.start!(
      user:      recipient,
      key:       key.to_s.strip,
      label:     label.to_s.strip,
      seconds:   seconds,
      again:     again.to_s.strip.presence,
      follow_up: { item: item.to_s.strip.presence, list: list.to_s.strip.presence },
    ).present?
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

  def duration_seconds(number, interval)
    unit = ROTATE_UNITS[interval.to_s.downcase.sub(/s?\z/, "s")]
    return 0 if unit.nil?

    @jil.cast(number, :Numeric).to_i * unit
  end

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

  # Who an alert is for: a comma-separated list of first names, "me", or a word
  # meaning the whole house. Blank is the task's own recipient.
  #
  # A list rather than one name because the common case for a household
  # condition is not "everybody" - it is the two people it concerns. An open
  # gate is open for whoever walks past it and the person who can shut it is
  # whoever happens to be home, but a housemate who has nothing to do with the
  # dog does not need a warning about the dog. "me, chelsea" says that; "house"
  # would say something bigger and slightly wrong, and the way that goes wrong
  # is an alert somebody learns to swipe away.
  #
  # Each person gets their own bubble in their own thread under the same key -
  # the one-open-per-key index is per user - so one `resolve` under that key
  # clears every one of them and nobody is left looking at a warning about
  # something already dealt with.
  #
  # A name that matches nobody reaches NOBODY, and the false that comes back is
  # the whole report. Falling back to the owner would put somebody else's alert
  # on his phone and look like it had worked.
  #
  # Same gate as `audience`: only people who already have a Buddy thread.
  # Nobody gets a companion spun up for them by a notification.
  def recipients_for(who)
    names = who.to_s.downcase.split(",").map(&:strip).compact_blank
    return [recipient] if names.empty?

    house = @jil.user.chore_household
    names.flat_map { |name|
      if ME.include?(name)
        [recipient]
      elsif HOUSEHOLD.include?(name)
        house ? with_companions(house.members) : [recipient]
      else
        Array(house&.member_named(name))
      end
    }.uniq
  end

  def with_companions(users)
    ids = ::ByteConversation.where(mode: :buddy).select(:user_id)
    users.where(id: ids).to_a
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
