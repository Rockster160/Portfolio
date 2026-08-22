module Buddy
  # Companion-to-companion messaging between household partners. One person's
  # Buddy relays a message (or question) to the OTHER person as a direct BRIDGED
  # message: the recipient sees it attributed to the SENDER's Buddy (icon / name
  # / accent color), and a copy lands in the sender's own thread attributed to
  # the RECIPIENT's Buddy — so each side renders the other household's identity,
  # like a cross-household chat. No recompose; the text is delivered verbatim.
  # See #bridge! for the two-sided post. A BuddyRelay row is the durable state
  # spanning the two users/conversations.
  #
  #   notify      -> bridge!: one-way message, both sides.
  #   ask_open    -> bridge!: the question, both sides; answered later when the
  #                  recipient replies (their Buddy sees the still-open relay in
  #                  context and emits [[relay_answer]]), which bridges back.
  #   ask_choice/ -> bridge! + a checkbox ByteAction on the recipient's copy; the
  #   ask_multi      answer comes through respond_action, then bridges back.
  module CompanionRelay
    class << self
      # ---- resolving the recipient + their conversation ----

      # The shared "where do unasked-for things go" picker — timers, alarms,
      # remind_when, the Jil buddy methods and agenda notify-others all resolve
      # their destination through here.
      def conversation_for(user)
        ByteConversation.for_self_initiated(user) ||
          user.byte_conversations.create!(mode: :buddy)
      end

      # ---- delivering a relay to the recipient ----

      # Send text from one person to another, now. The single path a message
      # between two people takes, whether it was typed a second ago
      # (message_partner) or set hours earlier and has only just come due (a
      # reminder or a watch aimed at somebody else).
      #
      # Those two used to poke the recipient's companion directly instead, which
      # delivered the words fine and left NO record on the sender's side. Prod
      # 2555-2569: a note set for Chelsea two minutes out arrived exactly as
      # asked, Rocco had no way to see that it had, asked "did it send?", got a
      # guess for an answer, and a second copy went out for real.
      #
      # `from_message:` is for the one case where the sender's words are ALREADY
      # a row in their thread - they long-pressed a relayed message and typed a
      # reply (Buddy::ThreadReply). Handed over, bridge! adopts that row as the
      # outgoing record instead of writing a second bubble saying the same thing.
      def pass_along!(from:, to:, text:, from_conversation: nil, from_message: nil)
        relay = BuddyRelay.create!(
          from_user:         from,
          to_user:           to,
          from_conversation: from_conversation || from_message&.byte_conversation || conversation_for(from),
          kind:              :notify,
          body:              text.to_s,
          status:            :pending,
        )
        deliver!(relay, from_message: from_message)
        # The row we made, not whatever delivery handed back. The record exists
        # either way, and a caller that wants its id shouldn't depend on how the
        # send went.
        relay
      end

      # How far back "the picture" reaches. A photo relay is always a follow-on
      # from something just posted — the camera frame Buddy pulled up a moment
      # ago — so the window is short on purpose. Reaching further would let
      # "send her the driveway" grab yesterday's doorbell.
      PHOTO_REACH = 15.minutes

      # Pass along a picture ALREADY in the thread, instead of a sentence about
      # one. "Send Chelsea a picture of the driveway" (prod 3731) came back as
      # "I can't grab or forward a driveway photo from here" — and the frame was
      # right there, one message up.
      #
      # Shared rather than copied (ByteMessageShare): what she opens is the same
      # row, so it carries the same file at full size and the same reactions,
      # and nothing has to keep two copies of a blob agreeing. Returns nil when
      # there's no recent picture, which the caller reports honestly rather than
      # claiming a send.
      def share_photo!(from:, to:, from_conversation: nil)
        photo = latest_photo(from_conversation || conversation_for(from))
        return nil if photo.nil?

        ByteMessageShare.share!(photo, conversation_for(to))
      end

      def latest_photo(conversation)
        scope = conversation.byte_messages.where(created_at: PHOTO_REACH.ago..)
        scope = scope.joins(:files_attachments).distinct
        scope.order(created_at: :desc).first
      end

      # Dispatch by kind. Returns the relay.
      def deliver!(relay, from_message: nil)
        case relay.kind.to_sym
        when :notify   then send_notify(relay, from_message: from_message)
        when :ask_open then send_open_question(relay)
        else                send_choice_question(relay)
        end
        relay
      end

      # notify / open question: a direct bridged message. The recipient sees it
      # attributed to the SENDER's Buddy; a copy lands in the sender's own thread
      # attributed to the RECIPIENT's Buddy (see #bridge!). Open questions get
      # answered later when the recipient replies (their Buddy sees the still-open
      # relay in context and emits [[relay_answer]]).
      def send_notify(relay, from_message: nil)
        res = bridge!(
          from_user: relay.from_user, to_user: relay.to_user,
          from_conversation: relay.from_conversation, text: relay.body,
          relay: relay, from_message: from_message
        )
        relay.update!(to_conversation: res[:to_conversation], status: :delivered, delivered_at: Time.current)
      end

      def send_open_question(relay)
        res = bridge!(
          from_user: relay.from_user, to_user: relay.to_user,
          from_conversation: relay.from_conversation, text: relay.body, relay: relay
        )
        relay.update!(to_conversation: res[:to_conversation], status: :delivered, delivered_at: Time.current)
      end

      # Structured pick-one / pick-any: the bridged question message on the
      # recipient's side carries a checkbox action; the sender's copy is just a
      # record. The recipient's answer returns through respond_buddy_relay.
      def send_choice_question(relay)
        action = nil
        # The buttons have to be on the message BEFORE it goes out. bridge!
        # broadcasts the recipient's copy the moment it creates it, so attaching
        # the action afterwards left the question sitting in their thread as
        # plain text with no way to answer it, until something unrelated redrew
        # the thread and the options finally appeared (prod 2212).
        res = bridge!(
          from_user: relay.from_user, to_user: relay.to_user,
          from_conversation: relay.from_conversation, text: choice_body(relay), relay: relay
        ) { |message| action = attach_answer_action(relay, message) }
        relay.update!(
          to_conversation: res[:to_conversation],
          to_byte_action:  action,
          status:          :delivered,
          delivered_at:    Time.current,
        )
        relay
      end

      # ---- capturing the answer + relaying it back ----

      # Records the recipient's answer (a String for open/choice, an Array for
      # multi) and hands it back to the asker's Buddy. Idempotent: a relay that
      # is no longer awaiting an answer is left untouched.
      def record_answer!(relay, answer, from_message: nil)
        return relay unless relay.delivered? && relay.question?

        relay.update!(answer: answer, status: :answered, answered_at: Time.current)
        relay_answer_back(relay, from_message: from_message)
        resume_sequence(relay)
        relay
      end

      # A question asked with `await_reply` has the rest of a sequence parked on
      # it. This is the only moment that can be known, and both ways of
      # answering — the answerer's `relay_answer` tool and a tapped choice
      # button — come through record_answer!, which is why the continuation
      # hangs here rather than on either path.
      #
      # Never allowed to take the answer down with it: the answer has already
      # been bridged by this point, and a broken follow-up step must not make it
      # look like they never replied.
      def resume_sequence(relay)
        return unless Buddy::ProposalBuilder.awaiting_reply?(relay)

        Buddy::ProposalBuilder.resume_after_reply!(relay)
      rescue StandardError => e
        Buddy::Errors.report(
          section:   "companion_relay.resume",
          exception: e,
          user:      relay.from_user,
          extra:     { relay_id: relay.id },
        )
      end

      # The answer flows back the other way: from the answerer (relay.to_user) to
      # the asker (relay.from_user). Same bridge — the asker sees the answer
      # attributed to the answerer's Buddy, the answerer gets a copy attributed to
      # the asker's. Delivered into the asker's original conversation.
      def relay_answer_back(relay, from_message: nil)
        res = bridge!(
          from_user: relay.to_user, to_user: relay.from_user,
          to_conversation: relay.from_conversation, text: formatted_answer(relay),
          relay: relay, from_message: from_message
        )
        relay.update!(status: :relayed, from_conversation: res[:to_conversation])
      end

      # A checkbox answer (choice/multi) came back from the recipient. Map the
      # tapped button ids to their option labels, record the answer, and lock
      # the checklist. `choice` collapses to a single string; `multi` stays an
      # array.
      def answer_from_action(action, checked_ids)
        relay = BuddyRelay.find_by(id: action.tool_input["relay_id"])
        return if relay.nil? || !relay.delivered?

        labels = Array(action.buttons)
          .select { |b| checked_ids.include?(b["id"].to_i) }
          .map { |b| b["label"].to_s }
        answer = relay.ask_multi? ? labels : labels.first

        record_answer!(relay, answer)
        finalize_action!(action, checked_ids)
        relay
      end

      private

      # Lock the recipient's checklist: mark tapped rows executed, the rest
      # cancelled, decide the action, and re-broadcast so the UI settles.
      def finalize_action!(action, checked_ids)
        action.apply_decision!(value: checked_ids.map(&:to_s), source: :user) if action.pending?

        buttons = Array(action.buttons).map(&:dup)
        buttons.each { |b| b["status"] = checked_ids.include?(b["id"].to_i) ? "executed" : "cancelled" }
        action.update!(buttons: buttons)

        message = action.byte_message
        return if message.nil?

        message.update!(metadata: message.metadata.merge("buttons" => buttons, "action_state" => "decided"))
        broadcast(action.user, message.reload)
      end

      # Post a bridged message from `from_user` to `to_user`. The recipient's
      # copy is attributed to the SENDER's Buddy (their icon/name/color) so they
      # see who it's from. A second copy lands in the SENDER's own thread as an
      # outgoing record: it carries BOTH identities (`relay_from` = their own
      # Buddy, `relay_peer` = the destination) so the UI can render it as
      # "yours → theirs" rather than as the partner talking. Recipient gets a
      # push; the sender copy is a silent record. No recompose — the text is
      # delivered verbatim in the sending Buddy's words.
      def bridge!(from_user:, to_user:, text:, from_conversation: nil, to_conversation: nil, relay: nil, from_message: nil)
        to_convo   = to_conversation || conversation_for(to_user)
        from_convo = from_message&.byte_conversation || from_conversation || conversation_for(from_user)
        sender     = peer_identity(from_user)
        recipient  = peer_identity(to_user)

        to_meta = { "kind" => "buddy_relay", "source" => "relay", "relay_peer" => sender }
        # Which relay this bubble belongs to. Everything else about a bridged
        # message describes the OTHER household's companion; nothing on it said
        # which row it came from, so a reply typed straight at it had no way
        # back to the person who sent it (Buddy::ThreadReply).
        to_meta["relay_id"] = relay.id if relay

        to_msg = to_convo.byte_messages.create!(
          user:         to_user,
          direction:    :inbound,
          state:        :delivered,
          body:         text,
          metadata:     to_meta,
          delivered_at: Time.current,
        )
        # Whatever else belongs ON the recipient's copy - a choice question's
        # answer buttons - attaches here, while it's still unsent. A message
        # broadcast half-built arrives half-built, and the rest of it only shows
        # up whenever the thread next happens to redraw.
        yield to_msg if block_given?
        broadcast(to_user, to_msg)
        push(to_user, "#{sender["name"]}: #{text}", conversation: to_convo)

        from_meta = {
          "kind"       => "buddy_relay",
          "source"     => "relay_copy",
          "relay_peer" => recipient,
          "relay_from" => sender,
          # Each copy points at the other, so a tapback on either one shows up
          # on both (Buddy::Reactions). Only settable in this direction at
          # create time — the recipient's copy is stamped below, once its twin
          # exists. Invisible plumbing, so the earlier broadcast going out
          # without it costs nothing.
          "relay_twin" => to_msg.id,
        }
        from_meta["relay_id"] = relay.id if relay

        # An adopted row is one the sender already typed and already sees. It
        # keeps its own direction and state — it is still their message, sitting
        # on their side of the thread — and only gains the attribution saying
        # where it went. Creating a second bubble here instead would put their
        # own words on the screen twice.
        from_msg = from_message || from_convo.byte_messages.new(
          user:         from_user,
          direction:    :inbound,
          state:        :delivered,
          body:         text,
          delivered_at: Time.current,
        )
        from_msg.metadata = from_msg.metadata.to_h.merge(from_meta)
        from_msg.save!
        broadcast(from_user, from_msg)
        to_msg.update!(metadata: to_msg.metadata.merge("relay_twin" => from_msg.id))

        { to_message: to_msg, from_message: from_msg, to_conversation: to_convo, from_conversation: from_convo }
      end

      # The other household's Buddy identity for an attribution header: pet name,
      # theme (drives the bubble accent color), and pet icon asset path.
      def peer_identity(user)
        theme  = ByteConversation.default_theme_for(user).to_s
        chrome = Buddy::Themes.for(theme)
        icon   = begin
          ActionController::Base.helpers.image_path(chrome[:avatar])
        rescue StandardError
          "/assets/#{chrome[:avatar]}"
        end
        { "name" => chrome[:name], "theme" => theme, "icon" => icon }
      end

      # ---- body copy ----

      def choice_body(relay)
        lead = "#{from_name(relay)} is asking:"
        tail = relay.ask_multi? ? " Check any that fit." : " Tap the one that fits."
        "#{lead} #{relay.body}#{tail}"
      end

      def formatted_answer(relay)
        if relay.ask_multi?
          picked = Array(relay.answer).compact_blank
          picked.any? ? picked.join(", ") : "none of them"
        else
          relay.answer.to_s.presence || "(no answer)"
        end
      end

      # ---- the recipient-side checkbox action ----

      def attach_answer_action(relay, message)
        buttons = Array(relay.options).each_with_index.map { |opt, i|
          { "id" => i + 1, "label" => opt.to_s, "tool_name" => "buddy_relay_answer", "status" => "pending" }
        }
        # NO EXPIRY. Every other action is a decision something is waiting on,
        # and the ten-minute default exists so a forgotten one can't wedge a
        # Claude turn forever. This is a question put to a PERSON, and the
        # ask_partner tools say it outright: they may take hours, or never reply
        # at all. Nothing is wedged in the meantime — the asker's side is its own
        # conversation, and a queued `await_reply` sequence is deliberately
        # parked until they answer.
        #
        # Prod 3586: Chelsea asked Rocco whether he wanted to watch something
        # while they ate, he came back to it twenty minutes later, and every tap
        # returned 409 with "tap to try again" — advice that could never work.
        # Before that, every relayed question had happened to be answered inside
        # nine minutes, so the fuse had never been reached.
        action = ByteAction.create!(
          user:              relay.to_user,
          byte_conversation: message.byte_conversation,
          byte_message:      message,
          kind:              :custom,
          tool_name:         "buddy_relay_answer",
          multi_select:      true,
          buttons:           buttons,
          tool_input:        { "relay_id" => relay.id, "mode" => relay.kind },
          never_expires:     true,
        )

        message.update!(metadata: message.metadata.merge(
          "kind"              => "buddy_reply",
          "tool_name"         => "buddy_relay_answer",
          "action_request_id" => action.request_id,
          "action_kind"       => "custom",
          "action_state"      => "pending",
          # The key the client actually greys stale rows off (see
          # multi_select.js and form.js). ProposalBuilder and FormAction both
          # send it; this path was the only one that didn't, which is why an
          # expired relay card rendered as perfectly live right up until the tap
          # came back refused. Nil now, and it stays honest if these are ever
          # given a fuse.
          "action_expires_at" => action.expires_at&.iso8601,
          "multi_select"      => true,
          "buttons"           => buttons,
          # "confirm" = pick-any with a Send button; "instant" = tap-to-answer.
          "select_mode"       => relay.ask_multi? ? "confirm" : "instant",
        ))
        action
      end

      # ---- shared broadcast / push (same shape as CompanionDelivery) ----

      def broadcast(user, message)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.as_wire },
        })
      end

      def push(user, title, conversation: nil)
        # Same rule as ByteNotifier — a relay that landed on the wall stays on
        # the wall. Reachable even though `conversation_for` now avoids the
        # kiosk, because a caller can hand over an explicit `to_conversation`.
        return if conversation&.kiosk?

        # Icon references become their names. A push has no pixels, and
        # "Rocco: [hicon:24] [hicon:22]" is the message arriving as its own
        # source code.
        WebPushNotifications.send_to_byte(
          title: "💬 #{::IconPool.refs_to_text(title, user: user).truncate(160)}",
          tag:   "byte-relay-#{user.id}-#{Time.current.to_i}",
          users: [user],
        )
      end

      def from_name(relay)
        relay.from_user.first_name.presence || "your partner"
      end
    end
  end
end
