class Jil::Methods::Buddy < Jil::Methods::Base
  def cast(value)
    @jil.cast(value, :String)
  end

  # Methods whose last argument is a block of named settings - `who`, `face` -
  # one line each, written as `Keyword.who("me")` and shown as just "who".
  NAMED_SETTINGS = %i[alert boardAlert dream mood timer message button miniAlert notice].freeze
  # Settings a block may give more than once, each line adding to the list.
  LISTED_SETTINGS = %i[who groups].freeze
  # Calls a block may hold besides its named lines, each collected under its
  # plural - `Buddy.button(...)` lines inside a `Buddy.message` block.
  NESTED_CALLS = { button: :buttons }.freeze

  def execute(line)
    return fallback(line) unless NAMED_SETTINGS.include?(line.methodname.to_sym)

    args = Array.wrap(line.args)
    block = args.last.is_a?(::Array) ? args.pop : nil
    send(line.methodname, *evalargs(args), named_settings(block))
  end

  # [Buddy]
  #   #say(Text)::Boolean
  #   #notice("Message" Text BR content([who:[%WHO%] icon:String color:String push:Boolean]))::Boolean
  #   #sayEvent("Event" Numeric|Hash|AgendaItem BR "Message" String)::Numeric
  #   #prompt(Text)::Boolean
  #   #photo("Image" String BR "Caption" String)::Boolean
  #   #checklist("List" String BR "Message" Text)::Numeric
  #   #alert("Key" String BR "Message" Text BR "Who" String BR "Groups" String BR "Icon" String)::Boolean
  #   #resolve("Key" String BR "Message" Text BR "Who" String)::Boolean
  #   #message("Key" String BR "Message" Text BR content([who:[%WHO%] Buddy.button]))::Numeric
  #   #button("Label" String BR content([trigger:String data:Hash resolve:Boolean resolved:String color:String]))::Hash
  #   #resolveMessage("Key" String BR "Message" Text BR "Who" String)::Boolean
  #   #miniAlert("Key" String BR "Label" String BR "Detail" String BR "Who" String BR content([color:String pinned:Boolean trigger:String data:Hash tap:String tapData:Hash]))::Boolean
  #   #clearMiniAlert("Key" String BR "Who" String)::Boolean
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

  # A banner in the thread instead of a message: the centered pill a tool
  # receipt uses, for news that only needs noting - the car arriving, a print
  # starting. It isn't unread and doesn't buzz the phone unless `push` is on.
  #
  # The block is optional: `who` as for `alert`, `icon` for the glyph at its
  # front (a message opening with one gives it up), `color` (green, blue,
  # purple, amber, red, or a hex) and `push`.
  #
  # Returns false when it reached nobody.
  def notice(message, options=nil)
    opts = options.to_h
    posted = recipients_for(Array(opts[:who]).join(",")).count { |user|
      ::Buddy::Notice.post!(
        user:     user,
        body:     message,
        icon:     opts[:icon],
        color:    opts[:color],
        push:     opts[:push] == true || opts[:push].to_s == "true",
        metadata: { source: :jil },
      ).present?
    }
    posted.positive?
  end

  # The same fixed message, but delivered to whoever the EVENT belongs to
  # rather than to whoever's task is running. Returns how many people it
  # reached, so a task can tell "nobody uses Buddy" from "sent".
  #
  # The travel alerts are the reason this exists. They are computed by the
  # task OWNER's tasks — the car and the address book are theirs — but the
  # event may be on somebody else's calendar, and "leave by 5:30" is no use to
  # the person not going. `Agenda#subject_users` is the whose-day-is-it rule; a personal
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
  # Returns false when it reached nobody - no key, no words, no companion thread
  # yet, or a name nobody in the house goes by - so a task can tell that from a
  # message that landed.
  #
  # Everything else is optional, one named line each in its block (see
  # `alert_options`).
  def alert(key, message, options=nil)
    opts = alert_options(options)
    delivered = recipients_for(opts[:who]).count { |user|
      ::Buddy::Alerts.raise!(user: user, key: key, body: message, **opts.except(:who)).present?
    }
    delivered.positive?
  end

  # The same condition as `alert`, shown ONLY on the boards its groups aim it at:
  # the pet's bubble and the face it holds, with no message in the thread, no
  # push and nothing in the chat strip. Re-asserting it while it stands changes
  # nothing, so a task can call it on every pass. Cleared with `resolve`. Use a
  # key of its own - one an `alert` also uses stays that alert.
  def boardAlert(key, message, options=nil)
    return false if message.to_s.strip.empty?

    opts = alert_options(options)
    held = recipients_for(opts[:who]).count { |user|
      ::Buddy::Alerts.hold!(user: user, key: key, body: message, **opts.except(:who)).present?
    }
    held.positive?
  end

  # A want or an idea, shown in the thought bubble of the boards its groups aim
  # it at - Whisper wanting food, something worth doing today. Board-only like
  # `boardAlert`: nothing in the thread, no push. The newest one sent is the one
  # a board shows, and the pet wears its face (thinking when blank) only while
  # nothing stronger wants the pet. Cleared with `resolve`.
  def dream(key, message, options=nil)
    return false if message.to_s.strip.empty?

    opts = alert_options(options)
    held = recipients_for(opts[:who]).count { |user|
      ::Buddy::Alerts.hold!(user: user, key: key, body: message, dream: true, **opts.except(:who)).present?
    }
    held.positive?
  end

  # A look and nothing else: the boards its groups aim it at have their pet wear
  # it while it stands, with no bubble, no message and no push. The look is a
  # `face` by name, or a mood on the faces' axes - `warmth`, `play`, `weight`,
  # `strain`, each 0 to 1, only the ones given counting - which every pet
  # answers with its own face. `reach` is how far from that point a face may be
  # and still be picked; blank leaves it to each face's own. Re-asserting it
  # while it stands changes nothing. Cleared with `resolve`.
  def mood(key, options=nil)
    opts = alert_options(options)
    return false if opts[:mood].nil? && opts[:expression].blank?

    held = recipients_for(opts[:who]).count { |user|
      ::Buddy::Alerts.hold!(user: user, key: key, body: nil, **opts.except(:who, :icon)).present?
    }
    held.positive?
  end

  # A message with buttons under it - a question for the people it concerns,
  # each in their own thread, answered by a press. Not an alert: nothing pins
  # and nothing stands open, so leaving it unanswered is fine.
  #
  # The block takes `who` lines like `alert`, and `Buddy.button(...)` lines,
  # one per button. `key` ties the copies together: one press can settle all
  # of them, and so can `resolveMessage` from another task. Sending again under
  # a key still waiting replaces the older one. Blank makes one up.
  #
  # Returns how many people it reached.
  def message(key, text, options=nil)
    opts = options.to_h
    ::Buddy::MessageButtons.send!(
      owner: @jil.user, users: recipients_for(Array(opts[:who]).join(",")),
      key: key, text: text, buttons: opts[:buttons],
    )
  end

  # One button for `message`. Pressing it fires `trigger` with `data` (a Hash),
  # as this task's owner, with `pressed_by` added - so what it does is whatever
  # listens there, built like any other automation. `resolve` (on unless set
  # false) settles every copy on the press; `resolved` is what they then say
  # instead of "<who> pressed ..."; `color` is `primary`, `danger` or a hex.
  def button(label, options=nil)
    options.to_h.merge(label: label.to_s)
  end

  # Settles a `message` from elsewhere - the thing it asked about happened by
  # itself. Its buttons go, and `message` (if any) shows where they were.
  # Returns false when nothing was waiting under that key.
  def resolveMessage(key, message, who=nil)
    ::Buddy::MessageButtons.settle!(owner: @jil.user, users: recipients_for(who), key: key, text: message).positive?
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

  # The hero's other notice: a chip pinned top-right, not the alert bar along
  # the bottom. Where `alert` is a standing CONDITION held open in the thread,
  # this is a small persistent marker on the hero itself - "the gate is open and
  # the dog is loose" sitting in the corner while it's true, gone the moment it
  # isn't.
  #
  # `key` is the chip's identity, the only coupling between what sets it and what
  # clears it. It travels in a URL path, so it must be lowercase with no dots or
  # slashes (colons are fine) - see `BackgroundProcess::KEY_RX`.
  #
  # `label` is the whole chip and gets about 20 characters; `detail` is its hover
  # title and can say more. `who` works exactly like `alert`'s - blank is the
  # task owner, a name reaches that person's hero, "house" reaches everyone -
  # but each hero is a window onto its own owner's machinery, so a shared
  # condition is usually set for one person.
  #
  # Raised as `waiting`: the stale and age-out sweeps leave `waiting`/`failed`
  # chips alone (`BackgroundProcess::PARKED`), which is what a standing condition
  # wants - it stays until something clears it rather than quietly ageing off the
  # strip while it's still true.
  #
  # The optional block is for a chip that stands for a state somebody is IN:
  # `color` (green, blue, purple, amber, red, or a hex), `pinned` to put it
  # ahead of every other chip, and `trigger` + `data` to fire when they tap its
  # × - so clearing it by hand is also how they end what it stands for.
  # `tap` + `tapData` fire on a tap of the chip itself. `clearMiniAlert` fires
  # nothing.
  #
  # Returns false when it reached nobody with a Buddy hero to show it.
  def miniAlert(key, label, detail=nil, who=nil, options=nil)
    # The block lands in whichever slot follows the last argument given.
    options, who = who, nil if who.is_a?(::Hash)
    options, detail = detail, nil if detail.is_a?(::Hash)
    opts = options.to_h
    look = {
      color:    opts[:color],
      pinned:   opts[:pinned],
      trigger:  opts[:trigger],
      data:     opts[:data],
      tap:      opts[:tap],
      tap_data: opts[:tapData],
      owner_id: @jil.user.id,
    }.compact
    posted = recipients_for(who).count { |user|
      ::BackgroundProcess.note(
        user: user, key: key.to_s, name: label.to_s,
        detail: detail.presence, state: :waiting, source: :jil, metadata: look
      ).present?
    }
    posted.positive?
  end

  # The condition passed - take the chip off the hero. Idempotent, and the same
  # key/who the chip went up with. Returns false when there was nothing open
  # under that key, the way `resolve` does, so a scheduled re-check can tell "I
  # just cleared one" from "already fine".
  def clearMiniAlert(key, who=nil)
    cleared = recipients_for(who).count { |user|
      ::BackgroundProcess.clear(user: user, key: key.to_s).present?
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
      place:     ::Buddy::Timers.placement(nil, board_id: pressed_board_id),
    ).present?
  end

  # A countdown on the hero. Everything but the length is optional, one named
  # line each in its block: `label`, `board` (one this account can reach, a
  # household member's shared board included) and `groups` (every board watching
  # one of them). A task run from a board's button lands on that board when
  # neither is given. Rings like any other Buddy timer. Returns false for a
  # length under a second; raises when the board named isn't one it can reach.
  def timer(number, interval, options=nil)
    seconds = duration_seconds(number, interval)
    return false if seconds < 1

    opts  = options.to_h
    board = opts[:board].to_s.strip
    named = (::Buddy::Timers.find_board!(recipient, board).id if board.present?)
    ::Buddy::BoardFeedGroups.remember!(recipient, opts[:groups])
    ::Buddy::Timers.create!(
      user:    recipient,
      seconds: seconds,
      label:   opts[:label].to_s.strip.presence,
      place:   ::Buddy::Timers.placement(nil, board_id: named || pressed_board_id, groups: Array(opts[:groups]).join(",")),
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

  # The settings block, one named line each:
  #
  # `who` is who it is FOR, one line per person: "me" (whoever's task this
  # is, and the default), "everyone" in the household, or a member by name.
  # The editor offers exactly those (Jil::Schema fills them in). See
  # `recipients_for`.
  # `groups` aims it at a board: a board shows it only when these overlap the
  # groups it watches, the same "any of these" match chores use. Blank means it
  # belongs to no board and stands in the chat strip alone. One line per group,
  # or a comma string ("Whisper, Puppy").
  # `icon` is an optional glyph (an emoji like "🍖") the BOARD shows in place of
  # the sentence, read from across the room where words can't be; the chat strip
  # keeps the words.
  # `face` is a face the board's pet holds while it stands - the laundry gate's
  # pounce - by name, typed freely. A system face (sleeping, thinking, wave)
  # every pet wears; any other only a pet with that drawing, and one without
  # keeps to its own feelings. A name no pet has is noted in the task's output
  # and changes nothing.
  # `warmth`, `play`, `weight`, `strain` (and `reach`) are the look as a mood -
  # see `mood` - which each pet answers with its own face; with a `face` too,
  # it's what a pet without that face wears.
  # Neither keeps the generic alarm shuffle (a dream thinks).
  # `strength` is how strongly that face wants the pet, on Buddy::FaceStrength's
  # 1-100 scale: the strongest face standing shows. Blank keeps the usual - an
  # alert's sits over a mood, a dream's only over an idle one.
  def alert_options(options)
    opts = options.to_h
    face = opts[:face].to_s.strip.presence
    if face && !::Buddy::Faces.known?(face)
      @jil.ctx[:output] << "No pet has a face called \"#{face}\" - they keep to their own feelings"
    end

    {
      who:        Array(opts[:who]).join(","),
      groups:     Array(opts[:groups]).flat_map { |g| g.to_s.split(",") }.map(&:strip).compact_blank,
      icon:       opts[:icon],
      expression: face,
      strength:   opts[:strength],
      mood:       ::Buddy::Moods.reading(opts.slice(*::Buddy::Moods::SETTINGS)),
    }
  end

  # `{ who: ["me", "Chelsea"], face: "eager" }` from the block's named lines.
  # Anything that isn't a named line is ignored rather than guessed at.
  def named_settings(block)
    Array.wrap(block).flatten.each_with_object({}) { |parser, settings|
      next unless parser.is_a?(::Jil::Parser)
      next if parser.commented? || parser.inline_comment?

      nested = NESTED_CALLS[parser.methodname.to_s.to_sym] if parser.objname == :Buddy
      next settings[nested] = [*settings[nested], @jil.execute_block(parser)] if nested
      next unless parser.objname == :Keyword

      name = parser.methodname.to_s
      next unless name.match?(/\A[a-z_]/)

      value = @jil.execute_block(parser)
      key = name.to_sym
      settings[key] = LISTED_SETTINGS.include?(key) ? [*settings[key], value] : value
    }
  end

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

  # The board whose button ran this task, so a timer it starts shows there.
  def pressed_board_id
    input = @jil.input_data
    input.is_a?(::Hash) ? input[:board_id].presence : nil
  end

  # Who the message is actually FOR, which is not always whose task this is.
  #
  # A SHARED task runs as its owner — `@jil.user` is the owner even when
  # somebody else asked, and that is deliberate: running as the owner is how the
  # task reaches their HASS credentials at all (Task#execute runs as
  # `task.user`). Delivering to `@jil.user` would answer the asker's question in
  # the owner's thread and
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
