require "rails_helper"

RSpec.describe "Buddy companion relay" do
  # Cross-user companion messaging: one person's Buddy relaying a message or a
  # question into their household partner's Buddy, and carrying answers back.
  describe "relaying between companions" do
    let(:rocco)   { create(:user) }
    let(:chelsea) { create(:user) }
    let(:her)     { chelsea.username } # what Rocco calls her (first_name == username here)
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: rocco) }
    let!(:convo) { ByteConversation.create!(user: rocco, mode: :buddy, name: "Buddy") }

    before do
      # ChoreHousehold auto-adds its owner (rocco) as a manager member.
      ChoreHouseholdMembership.create!(chore_household: household, user: chelsea, role: :member)
      rocco.update!(chore_household_id: household.id)
      chelsea.update!(chore_household_id: household.id)

      # Relays now post direct bridged messages (broadcast + push), no recompose.
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      # Random test users aren't in MOSS_USER_IDS, so differentiate the two
      # households' themes explicitly for the attribution assertions.
      allow(ByteConversation).to receive(:default_theme_for) { |u| u == chelsea ? "moss" : "byte" }
    end

    def source(conversation, src)
      conversation.byte_messages.where("metadata->>'source' = ?", src).order(:created_at).last
    end

    def run(tool_name, payload, user: rocco, conversation: convo)
      tool = Buddy::Tools[tool_name]
      ctx  = Buddy::ToolContext.new(user, conversation: conversation)
      confirm = tool[:confirm].call(payload, ctx)
      tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx)
    end

    # ---- sending: notify + the three ask kinds ----

    describe "message_partner (notify)" do
      it "bridges the message to the partner and drops an attributed copy for the sender" do
        run(:message_partner, { to: her, message: "he fed the dog" })

        relay = BuddyRelay.last
        expect(relay).to have_attributes(from_user: rocco, to_user: chelsea, kind: "notify", status: "delivered")

        # Chelsea sees it attributed to Rocco's Buddy (Byte).
        to_msg = source(relay.to_conversation, "relay")
        expect(to_msg.body).to eq("he fed the dog")
        expect(to_msg.metadata.dig("relay_peer", "name")).to eq("Byte")

        # Rocco's own thread gets an outgoing copy carrying both identities, so
        # it renders as "Byte → Moss" instead of looking like Moss said it.
        copy = source(convo, "relay_copy")
        expect(copy.body).to eq("he fed the dog")
        expect(copy.metadata.dig("relay_from", "name")).to eq("Byte")
        expect(copy.metadata.dig("relay_peer", "name")).to eq("Moss")
      end

      it "leaves the recipient's copy without a sender-side arrow" do
        run(:message_partner, { to: her, message: "he fed the dog" })

        expect(source(BuddyRelay.last.to_conversation, "relay").metadata).not_to have_key("relay_from")
      end

      it "refuses a name that isn't in the household" do
        tool = Buddy::Tools[:message_partner]
        ctx  = Buddy::ToolContext.new(rocco, conversation: convo)
        expect { tool[:confirm].call({ to: "Nobody", message: "hi" }, ctx) }.to raise_error(/not sure who/)
      end
    end

    describe "ask_partner (open)" do
      it "creates an ask_open relay awaiting an answer" do
        run(:ask_partner, { to: her, question: "what she wants for dinner" })

        relay = BuddyRelay.last
        expect(relay).to have_attributes(kind: "ask_open", status: "delivered")
        expect(BuddyRelay.open_questions_for(chelsea)).to include(relay)
      end
    end

    describe "ask_partner_choice / ask_partner_multi" do
      it "attaches a checkbox action with one row per option (choice = instant)" do
        run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })

        relay = BuddyRelay.last
        expect(relay.kind).to eq("ask_choice")
        action = relay.to_byte_action
        expect(action.tool_name).to eq("buddy_relay_answer")
        expect(action.buttons.pluck("label")).to eq(%w[dishes mop])
        expect(relay.to_conversation.byte_messages.last.metadata["select_mode"]).to eq("instant")
      end

      it "marks multi questions as confirm-mode (Send button)" do
        run(:ask_partner_multi, { to: her, question: "which resonate?", options: "words, time, touch" })

        relay = BuddyRelay.last
        expect(relay.kind).to eq("ask_multi")
        expect(relay.to_conversation.byte_messages.last.metadata["select_mode"]).to eq("confirm")
      end

      it "rejects fewer than two options" do
        tool = Buddy::Tools[:ask_partner_choice]
        ctx  = Buddy::ToolContext.new(rocco, conversation: convo)
        expect { tool[:confirm].call({ to: her, question: "?", options: "only one" }, ctx) }
          .to raise_error(/at least two/)
      end

      # Prod 2212: the question landed in Rocco's thread as plain text with no way
      # to answer it, and the buttons only turned up later. The message went out
      # the instant it was created, and the action was attached after.
      it "sends the question with its answers already on it" do
        sent = []
        allow(MonitorChannel).to receive(:broadcast_to) { |user, payload|
          sent << payload.dig(:data, :message) if user == chelsea
        }

        run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })

        question = sent.find { |m| m[:metadata]["source"] == "relay" }
        expect(question[:metadata]["buttons"].pluck("label")).to eq(%w[dishes mop])
        expect(question[:metadata]["select_mode"]).to eq("instant")
      end

      it "only sends it once, so the options don't arrive as a second draw" do
        sent = []
        allow(MonitorChannel).to receive(:broadcast_to) { |user, payload|
          sent << payload.dig(:data, :message) if user == chelsea
        }

        run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })

        expect(sent.count { |m| m[:metadata]["source"] == "relay" }).to eq(1)
      end

      it "leaves a plain message alone - there's nothing to attach" do
        run(:message_partner, { to: her, message: "he fed the dog" })

        expect(BuddyRelay.last.to_conversation.byte_messages.last.metadata).not_to have_key("buttons")
      end
    end

    # ---- answering ----

    describe "answering a checkbox question" do
      it "records a single choice and relays it back to the asker" do
        run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })
        relay  = BuddyRelay.last
        action = relay.to_byte_action

        Buddy::CompanionRelay.answer_from_action(action, [2]) # "mop"

        expect(relay.reload).to have_attributes(answer: "mop", status: "relayed")
        expect(action.reload.buttons.find { |b| b["id"] == 2 }["status"]).to eq("executed")
        expect(action.buttons.find { |b| b["id"] == 1 }["status"]).to eq("cancelled")

        # The answer is bridged back to Rocco, attributed to Chelsea's Buddy (Moss).
        answer_msg = source(convo, "relay")
        expect(answer_msg.body).to eq("mop")
        expect(answer_msg.metadata.dig("relay_peer", "name")).to eq("Moss")
      end

      it "records a multi answer as the full set of picked labels" do
        run(:ask_partner_multi, { to: her, question: "which resonate?", options: "words, time, touch" })
        relay  = BuddyRelay.last
        action = relay.to_byte_action

        Buddy::CompanionRelay.answer_from_action(action, [1, 3]) # words + touch

        expect(relay.reload.answer).to eq(%w[words touch])
        expect(relay.status).to eq("relayed")
      end

      it "is idempotent - a second answer is ignored" do
        run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })
        relay  = BuddyRelay.last
        action = relay.to_byte_action

        Buddy::CompanionRelay.answer_from_action(action, [1])
        Buddy::CompanionRelay.answer_from_action(action, [2])

        expect(relay.reload.answer).to eq("dishes")
      end
    end

    describe "relay_answer tool (open-ended, from the recipient's Buddy)" do
      it "records the free-text answer and relays it back" do
        run(:ask_partner, { to: her, question: "dinner?" })
        relay = BuddyRelay.last

        tool = Buddy::Tools[:relay_answer]
        ctx  = Buddy::ToolContext.new(chelsea, conversation: convo)
        confirm = tool[:confirm].call({ id: relay.id, answer: "tacos" }, ctx)
        tool[:execute].call({ id: relay.id, answer: "tacos" }.merge(confirm[:resolved]), ctx)

        expect(relay.reload).to have_attributes(answer: "tacos", status: "relayed")
      end

      it "does not answer someone else's relay" do
        run(:ask_partner, { to: her, question: "dinner?" })
        relay = BuddyRelay.last

        tool = Buddy::Tools[:relay_answer]
        # rocco is the ASKER, not the recipient - no open question addressed to him.
        ctx  = Buddy::ToolContext.new(rocco, conversation: convo)
        expect { tool[:confirm].call({ id: relay.id, answer: "x" }, ctx) }.to raise_error(/no open question/)
      end
    end

    # ---- context surfaces open questions to the recipient ----

    describe "context pending_relays" do
      it "lists open questions addressed to the user" do
        run(:ask_partner, { to: her, question: "dinner?" })
        relay = BuddyRelay.last

        relays = Buddy::Context.send(:pending_relays, chelsea)
        expect(relays).to include(hash_including(id: relay.id, from: rocco.first_name, question: "dinner?"))
      end

      it "drops a question once it's answered" do
        run(:ask_partner, { to: her, question: "dinner?" })
        Buddy::CompanionRelay.record_answer!(BuddyRelay.last, "tacos")

        expect(Buddy::Context.send(:pending_relays, chelsea)).to be_empty
      end

      # Prod Aug 7: Chelsea asked "Are we leaving at 5:30?" on Aug 3. Nobody
      # answered and nothing closed it, so it was still listed as an open
      # question through four days of unrelated conversation — and when a stray
      # "Tick" arrived from the CLI, Buddy did exactly what an open question tells
      # it to do and sent "Tick" back to her as Rocco's answer.
      #
      # The measure is messages, not minutes: an answer is the next thing they
      # say, and anything else means the question went by.
      describe "a question that went unanswered" do
        let!(:her_convo) {
          chelsea.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: Time.current)
        }
        let!(:question) {
          run(:ask_partner, { to: her, question: "Are we leaving at 5:30?" })
          BuddyRelay.last
        }

        def she_says(body)
          her_convo.byte_messages.create!(user: chelsea, direction: :outbound, state: :sent, body: body)
        end

        def open_now
          Buddy::Context.send(:pending_relays, chelsea, her_convo)
        end

        it "is open on the very next thing she says" do
          she_says("Tick")

          expect(open_now).to include(hash_including(id: question.id))
        end

        it "is gone the moment she has said anything else first" do
          she_says("what's the weather")
          she_says("Tick")

          expect(open_now).to be_empty
        end

        # The boundary, stated exactly: the first message after the question is
        # the chance to answer it, and the second one has already passed it over.
        # One is enough — it doesn't take a hundred, or three days.
        it "closes on the second message, not the first" do
          she_says("Tick")
          expect(open_now).not_to be_empty

          she_says("Tick")
          expect(open_now).to be_empty
        end

        it "can no longer be answered, so nothing stray gets passed along" do
          she_says("what's the weather")
          she_says("Tick")
          tool = Buddy::Tools[:relay_answer]
          ctx  = Buddy::ToolContext.new(chelsea, conversation: her_convo)

          expect { tool[:confirm].call({ id: question.id, answer: "Tick" }, ctx) }
            .to raise_error(/no open question/)
          expect(question.reload.answer).to be_blank
        end

        # Days of silence say nothing either way — what matters is whether she
        # spoke without answering.
        it "survives a long gap as long as she hasn't spoken since" do
          question.update!(created_at: 2.weeks.ago)
          she_says("Tick")

          expect(open_now).to include(hash_including(id: question.id))
        end

        it "doesn't count Buddy's own hidden seeds as her passing it over" do
          her_convo.byte_messages.create!(
            user: chelsea, direction: :outbound, state: :sent, body: "[tapped Today]",
            metadata: { "hidden" => true, "kind" => "buddy_trigger" }
          )
          she_says("Tick")

          expect(open_now).to include(hash_including(id: question.id))
        end
      end
    end

    # Prod 3731: "Send Chelsea a picture of the driveway" came back as "I can't
    # grab or forward a driveway photo from here" — with the frame one message up
    # in the same thread. The relay only ever carried text.
    #
    # Now it carries the frame by SHARING it (ByteMessageShare) rather than
    # copying the blob, so she opens the same row at full size, and a reaction on
    # it is one reaction rather than two that have to be kept level.
    describe "relaying a photo" do
      def frame!(at: Time.current, conversation: convo)
        msg = conversation.byte_messages.create!(
          user: rocco, direction: :inbound, state: :delivered,
          body: "Driveway, just now", created_at: at
        )
        msg.files.attach(
          io: StringIO.new("not-really-a-jpeg"), filename: "driveway.jpg", content_type: "image/jpeg",
        )
        msg
      end

      it "shows her the same row instead of a second copy of the picture" do
        photo = frame!

        expect { run(:message_partner, { to: her, message: "someone out front", with_photo: true }) }
          .to change(ByteMessageShare, :count).by(1)

        hers = BuddyRelay.last.to_conversation
        expect(hers.visible_messages).to include(photo)
        expect(hers.byte_messages).not_to include(photo)
        expect(photo.reload.files.count).to eq(1)
      end

      it "says the photo went" do
        frame!
        result = run(:message_partner, { to: her, message: "someone out front", with_photo: true })

        expect(result[:photo_sent]).to be(true)
        expect(Buddy::Tools[:message_partner][:receipt].call(result, nil)).to include("the photo")
      end

      # The note still goes. What must not happen is a receipt claiming a picture
      # went when there wasn't one — that's the camera failure all over again.
      it "admits it when there's no picture to send" do
        result = run(:message_partner, { to: her, message: "someone out front", with_photo: true })

        expect(result[:photo_sent]).to be(false)
        expect(BuddyRelay.last.body).to eq("someone out front")
        expect(Buddy::Tools[:message_partner][:receipt].call(result, nil)).to include("no recent picture")
      end

      it "doesn't reach back for an older picture" do
        frame!(at: 2.hours.ago)
        result = run(:message_partner, { to: her, message: "someone out front", with_photo: true })

        expect(result[:photo_sent]).to be(false)
      end

      it "sends nothing extra when the note isn't about a picture" do
        frame!

        expect { run(:message_partner, { to: her, message: "he fed the dog" }) }
          .not_to change(ByteMessageShare, :count)
      end
    end
  end

  # Prod 3303. "Tell Rocco I'll make supper at 6:00 tonight." became a
  # `schedule_reminder` aimed at Rocco with `at` set to 6:00 PM — so the news that
  # supper was coming at six would have arrived at six. Chelsea corrected it
  # ("No I want him to know that I plan to make supper at 6:00"), it relayed
  # properly on the retry, and then she spent four more messages getting the
  # stray reminder deleted.
  #
  # The 6:00 was never a delivery time. It was what the message was ABOUT, and
  # both tool descriptions listed bare times ("at 4", "tonight") as the tell for
  # the later form — the exact tokens that show up inside an ordinary note.
  describe "send times" do
    let(:relay) { Buddy::Tools[:message_partner][:description] }
    let(:later) { Buddy::Tools[:schedule_reminder][:description] }

    describe "message_partner" do
      it "puts the delay in the instruction rather than in the note" do
        expect(relay).to match(/a delay is in the instruction, never in the note/i)
      end

      it "carries the case that broke, with its answer" do
        expect(relay).to include("Tell Rocco I'll make supper at 6:00 tonight")
        expect(relay).to match(/send it NOW/)
      end

      it "contrasts a time in the content with a time in the framing" do
        expect(relay).to include("Tell Chelsea I'm leaving at 4")
        expect(relay).to include("Remind Chelsea at 4 that I'm leaving")
      end

      it "settles the ambiguous case toward sending" do
        expect(relay).to match(/when the sentence carries one time and you can(?:'|’)t place it, it(?:'|’)s content/i)
      end

      # The examples for the LATER form have to be framings, or they teach the
      # failure they're meant to prevent.
      it "no longer offers a bare time as the tell for scheduling" do
        expect(relay).to include("send it to her in five minutes", "tell him at 4")
        expect(relay).not_to include(%(At a time ("in five minutes", "at 4", "tonight")))
      end
    end

    describe "schedule_reminder" do
      it "says the same thing from the other side" do
        expect(later).to match(/`at` comes from WHEN THEY SAID TO SEND IT/)
        expect(later).to match(/a time inside the note is part of the note/i)
      end

      it "names the tool to use instead" do
        expect(later).to match(/use `message_partner`/)
      end
    end
  end

  # Prod 1434-1440, two failures in one exchange.
  #
  # "Tell Chelsea: I love you more! And I like YOUR butt!" arrived as "...I like
  # your butt!" - message_partner WAS called, but the model retyped the words and
  # flattened the shouted one, which was the whole joke.
  #
  # Then "Tell Chelsea: Rude. Byte took away my formatting!" produced "Sent. 😅"
  # followed by a verbatim `[you passed this along to Moss] ...` - the bracketed
  # attribution History puts on a bridged message so Buddy can READ it. No tool
  # call, no relay row, no receipt chip. Nothing reached Chelsea, and neither the
  # nudge nor the retraction noticed, because "Sent." matched no claim pattern.
  describe "word for word" do
    describe "carrying the person's words intact" do
      let(:tool) { Buddy::Tools[:message_partner] }

      it "tells the model the words are theirs when they hand over words" do
        expect(tool[:description]).to include("Copy it EXACTLY")
        expect(tool[:description]).to include("I like YOUR butt!")
        expect(tool[:description]).to match(/do not tidy/i)
      end

      it "still lets the model do the phrasing when it only got the gist" do
        expect(tool[:description]).to include("The wording is yours")
      end

      it "says the same thing on the question side" do
        expect(Buddy::Tools[:ask_partner][:description]).to match(/gave you the words/i)
      end

      it "puts it in the prompt too, not just the tool schema" do
        convo = User.me.byte_conversations.create!(mode: :buddy)

        expect(Buddy::Personality.for(User.me, conversation: convo)).to include(
          "You're the envelope, not the editor",
        )
      end
    end

    # Prod 2212. Chelsea: "Ask Rocco if he will learn how to play American mahjong
    # with me". What reached Rocco was "Will you learn how to play American
    # mahjong with you?" - the model turned BOTH people into the second person, so
    # the question asked him to do it with himself. Half the swap is right ("if he
    # will" is addressed as "will you"); the other half has to become a name.
    describe "which person the words are written to" do
      # Squished the way function_schema squishes it, so a line wrap in the
      # heredoc isn't the thing these assertions are about.
      def described(name)
        Buddy::Tools[name][:description].strip.gsub(/\s+/, " ")
      end

      %i[ask_partner ask_partner_choice ask_partner_multi].each { |name|
        it "tells #{name} that \"you\" means the recipient" do
          expect(described(name)).to match(/READ BY (them|the person being asked)/i)
          expect(described(name)).to match(/your own person (gets|is) named/i)
        end

        it "says it on #{name}'s question argument, where the value is written" do
          expect(Buddy::Tools[name][:args][:question][:description]).to match(/addressed TO them/i)
        end
      }

      it "works the case out in the prompt, with the sentence that broke" do
        convo = User.me.byte_conversations.create!(mode: :buddy)
        prompt = Buddy::Personality.for(User.me, conversation: convo)

        expect(prompt).to include("Will you learn American mahjong with you?")
        expect(prompt).to include("\"you\" is the recipient and nobody else")
      end
    end

    # Prod: "Ask Rocco if we're leaving at 5:30" got "Rocco's wondering if you're
    # leaving at 5:30" - the direction inverted, no tool called, and she had to
    # send it again. The prompt was teaching that: a bullet about incoming relays
    # described a "hidden seed" flow that no longer exists (bridge! delivers
    # verbatim and seeds nothing) and handed over two finished sentences using a
    # real household name, one of which came back almost word for word.
    describe "which direction a relay is going" do
      let(:prompt) {
        Buddy::Personality.for(User.me, conversation: User.me.byte_conversations.create!(mode: :buddy))
      }

      it "no longer promises a seed for something arriving from someone else" do
        expect(prompt).not_to match(/hidden seed will ask you to pass a message along/i)
        expect(prompt).to include("this needs nothing from you")
      end

      it "doesn't hand over a ready-made go-between line to copy" do
        expect(prompt).not_to include("wanted me to let you know")
        expect(prompt).not_to match(/'s wondering what you're feeling for dinner/)
      end

      it "says an ask/tell from their OWN person is the tool, not a narration" do
        expect(prompt).to include("the reply is the call")
        expect(prompt).to include("Ask Rocco if we're leaving at 5:30")
      end
    end

    describe Buddy::GPT::Turn do
      # The exact body that went out in prod.
      let(:faked) { "Sent. 😅\n\n[you passed this along to Moss] Rude. Byte took away my formatting!" }

      it "reads a bare \"Sent.\" as a claim so an uncalled relay gets a corrective round" do
        expect(described_class.unbacked_claim("Sent. 😅")).to eq(:claim)
        expect(described_class.unbacked_claim("Passed it along to Chelsea.")).to eq(:claim)
        expect(described_class.unbacked_claim("Told her already.")).to eq(:claim)
        expect(described_class.unbacked_claim("She's in the loop now.")).to eq(:claim)
      end

      # Writing the attribution IS the claim: the only reason that bracket exists
      # is to label a relay that actually happened.
      it "reads the relay attribution itself as a claim, even with no other words" do
        expect(described_class.unbacked_claim("[you passed this along to Moss] Rude.")).to eq(:claim)
        expect(described_class.unbacked_claim(faked)).to eq(:claim)
      end

      it "leaves an offer to send alone - a promise is not a claim" do
        expect(described_class.unbacked_claim("Want me to send that along?")).to be_nil
        expect(described_class.unbacked_claim("Let me know and I'll tell her.")).to be_nil
      end
    end
  end

  # Prod 3586. Chelsea asked Rocco, through Moss, whether he wanted to watch
  # something while they ate. He came back to it twenty minutes later, tapped
  # "yes", and got "Couldn't do that just now — tap to try again" — every time,
  # forever, because the action had expired ten minutes after it was asked.
  #
  # Two things were wrong and each hid the other: the card had a ten-minute fuse
  # it had no business having, and the client was never told, so it rendered as
  # perfectly live. Every earlier relayed question happened to be answered inside
  # nine minutes, so nothing had ever reached the fuse.
  describe "questions that outlive the turn" do
    let(:asker)   { create(:user) }
    let(:partner) { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: asker) }
    let!(:asker_convo) {
      asker.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: Time.current)
    }
    let!(:partner_convo) {
      partner.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(::WebPushNotifications).to receive(:update_count)
      ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
      asker.update!(chore_household_id: household.id)
      partner.update!(chore_household_id: household.id)
    end

    def ask!
      relay = BuddyRelay.create!(
        from_user: asker, to_user: partner, from_conversation: asker_convo,
        kind: :ask_choice, body: "Will you watch Apothecary while we eat?",
        options: %w[yes no], status: :pending
      )
      Buddy::CompanionRelay.deliver!(relay)
      relay
    end

    def action_for(relay)
      ByteAction.find_by(tool_name: "buddy_relay_answer", user_id: relay.to_user_id)
    end

    it "leaves the question open with no fuse on it" do
      action = action_for(ask!)

      expect(action.expires_at).to be_nil
    end

    # The specific failure: twenty minutes later, the tap still works.
    it "still answers long after the old ten-minute window" do
      relay  = ask!
      action = action_for(relay)

      travel_to(25.minutes.from_now) do
        expect(action.reload).to be_pending
        expect(ByteAction.active).to include(action)
      end
    end

    it "still counts as active a day later" do
      action = action_for(ask!)

      travel_to(1.day.from_now) { expect(ByteAction.active).to include(action) }
    end

    # The client greys stale rows off `action_expires_at` and nothing else. This
    # path was the only one of the three that never sent it, so an expired card
    # looked live right up until the tap came back refused.
    it "tells the client what it knows about the expiry" do
      ask!
      card = partner_convo.byte_messages.where("metadata->>'tool_name' = 'buddy_relay_answer'").last

      expect(card.metadata).to have_key("action_expires_at")
      expect(card.metadata["action_expires_at"]).to be_nil
    end

    # The default is still the default. Nothing else loses its fuse, because the
    # reason for it — a forgotten action wedging a Claude turn — is real.
    describe "everything else" do
      it "keeps the ten-minute default" do
        action = ByteAction.create!(
          user: asker, byte_conversation: asker_convo, kind: :custom,
          tool_name: "something_else", buttons: [], multi_select: false
        )

        expect(action.expires_at).to be_within(5.seconds).of(ByteAction::DEFAULT_TTL.from_now)
      end

      # A caller-supplied nil is indistinguishable from silence under `||=`, which
      # is precisely how the relay card ended up on a fuse. The flag is what says
      # it out loud.
      it "isn't fooled by an explicit nil" do
        action = ByteAction.create!(
          user: asker, byte_conversation: asker_convo, kind: :custom,
          tool_name: "something_else", buttons: [], multi_select: false, expires_at: nil
        )

        expect(action.expires_at).to be_present
      end

      it "still honours an explicit expiry" do
        action = ByteAction.create!(
          user: asker, byte_conversation: asker_convo, kind: :custom,
          tool_name: "something_else", buttons: [], multi_select: false,
          expires_at: 2.hours.from_now
        )

        expect(action.expires_at).to be_within(5.seconds).of(2.hours.from_now)
      end
    end
  end
end
