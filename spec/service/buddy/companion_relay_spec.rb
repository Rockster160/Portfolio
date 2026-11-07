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

      # Relays post direct bridged messages (broadcast + push), no recompose.
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

    # The partner's thread receives broadcast frames; this captures hers.
    def frames_to(user)
      sent = []
      allow(MonitorChannel).to receive(:broadcast_to) { |u, payload|
        sent << payload.dig(:data, :message) if u == user
      }
      sent
    end

    # ---- sending: notify + the three ask kinds ----

    describe "message_partner (notify)" do
      it "bridges the message to the partner and drops an attributed copy for the sender", :aggregate_failures do
        run(:message_partner, { to: her, message: "he fed the dog" })

        relay = BuddyRelay.last
        expect(relay).to have_attributes(from_user: rocco, to_user: chelsea, kind: "notify", status: "delivered")

        # Chelsea sees it attributed to Rocco's Buddy (Byte), with no sender-side arrow
        # and no buttons.
        to_msg = source(relay.to_conversation, "relay")
        expect(to_msg.body).to eq("he fed the dog")
        expect(to_msg.metadata.dig("relay_peer", "name")).to eq("Byte")
        expect(to_msg.metadata).not_to have_key("relay_from")
        expect(to_msg.metadata).not_to have_key("buttons")

        # Rocco's own thread gets an outgoing copy carrying both identities, so
        # it renders as "Byte → Moss" instead of looking like Moss said it.
        copy = source(convo, "relay_copy")
        expect(copy.body).to eq("he fed the dog")
        expect(copy.metadata.dig("relay_from", "name")).to eq("Byte")
        expect(copy.metadata.dig("relay_peer", "name")).to eq("Moss")
      end

      # The pet lives on the THREAD; the account's default pet cannot tell two
      # of their threads apart.
      context "when the sender has more than one companion" do
        let!(:her_second) {
          ByteConversation.create!(
            user: chelsea, mode: :buddy, name: "Kumoko", buddy_theme: :kumoko, theme_chosen: true,
          )
        }

        it "attributes and pushes the message as the companion she sent it from" do
          run(
            :message_partner, { to: rocco.first_name, message: "dinner at six" },
            user: chelsea, conversation: her_second
          )

          to_msg = source(BuddyRelay.last.to_conversation, "relay")
          expect(to_msg.metadata.dig("relay_peer", "name")).to eq("Kumoko")
          expect(to_msg.metadata.dig("relay_peer", "theme")).to eq("kumoko")
          expect(WebPushNotifications).to have_received(:send_to_byte)
            .with(hash_including(title: a_string_including("Kumoko")))
        end

        it "threads an answer back to the companion that asked" do
          run(
            :ask_partner, { to: rocco.first_name, question: "pizza or pasta?" },
            user: chelsea, conversation: her_second
          )
          relay = BuddyRelay.last
          Buddy::CompanionRelay.record_answer!(relay, "pizza")

          expect(relay.reload.from_conversation).to eq(her_second)
          answer = source(her_second, "relay")
          expect(answer.body).to include("pizza")
          expect(answer.metadata.dig("relay_peer", "name")).to eq("Byte")
        end
      end

      it "refuses a name that isn't in the household" do
        tool = Buddy::Tools[:message_partner]
        ctx  = Buddy::ToolContext.new(rocco, conversation: convo)
        expect { tool[:confirm].call({ to: "Nobody", message: "hi" }, ctx) }.to raise_error(/not sure who/)
      end
    end

    it "opens an ask_open relay awaiting an answer, listed in her context until answered" do
      run(:ask_partner, { to: her, question: "dinner?" })

      relay = BuddyRelay.last
      expect(relay).to have_attributes(kind: "ask_open", status: "delivered")
      expect(BuddyRelay.open_questions_for(chelsea)).to include(relay)
      expect(Buddy::Context.send(:pending_relays, chelsea))
        .to include(hash_including(id: relay.id, from: rocco.first_name, question: "dinner?"))

      Buddy::CompanionRelay.record_answer!(relay, "tacos")

      expect(Buddy::Context.send(:pending_relays, chelsea)).to be_empty
    end

    describe "ask_partner_choice / ask_partner_multi" do
      # The question has to go out with its buttons already on it, in a single
      # frame, or it lands as plain text with no way to answer.
      it "sends one checkbox question carrying a row per option, instant-select", :aggregate_failures do
        sent = frames_to(chelsea)

        run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })

        relay = BuddyRelay.last
        expect(relay.kind).to eq("ask_choice")
        action = relay.to_byte_action
        expect(action.tool_name).to eq("buddy_relay_answer")
        expect(action.buttons.pluck("label")).to eq(%w[dishes mop])
        expect(relay.to_conversation.byte_messages.last.metadata["select_mode"]).to eq("instant")

        questions = sent.select { |m| m[:metadata]["source"] == "relay" }
        expect(questions.length).to eq(1)
        expect(questions.first[:metadata]["buttons"].pluck("label")).to eq(%w[dishes mop])
        expect(questions.first[:metadata]["select_mode"]).to eq("instant")
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
    end

    # ---- answering ----

    describe "answering a checkbox question" do
      it "records a single choice once, relays it back, and ignores a second answer", :aggregate_failures do
        run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })
        relay  = BuddyRelay.last
        action = relay.to_byte_action

        Buddy::CompanionRelay.answer_from_action(action, [2]) # "mop"
        Buddy::CompanionRelay.answer_from_action(action, [1])

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

      it "is open on the very next thing she says, and closes on the second" do
        she_says("Tick")
        expect(open_now).to include(hash_including(id: question.id))

        she_says("Tick")
        expect(open_now).to be_empty
      end

      it "can no longer be answered once she has said anything else first" do
        she_says("what's the weather")
        she_says("Tick")
        tool = Buddy::Tools[:relay_answer]
        ctx  = Buddy::ToolContext.new(chelsea, conversation: her_convo)

        expect(open_now).to be_empty
        expect { tool[:confirm].call({ id: question.id, answer: "Tick" }, ctx) }
          .to raise_error(/no open question/)
        expect(question.reload.answer).to be_blank
      end

      # Days of silence say nothing either way, and Buddy's own hidden seeds
      # aren't her speaking.
      it "survives a long gap and hidden seeds as long as she hasn't spoken since" do
        question.update!(created_at: 2.weeks.ago)
        her_convo.byte_messages.create!(
          user: chelsea, direction: :outbound, state: :sent, body: "[tapped Today]",
          metadata: { "hidden" => true, "kind" => "buddy_trigger" }
        )
        she_says("Tick")

        expect(open_now).to include(hash_including(id: question.id))
      end
    end

    # The relay carries the frame by SHARING it (ByteMessageShare) rather than
    # copying the blob, so she opens the same row at full size.
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
        photo  = frame!
        result = nil

        expect { result = run(:message_partner, { to: her, message: "someone out front", with_photo: true }) }
          .to change(ByteMessageShare, :count).by(1)

        hers = BuddyRelay.last.to_conversation
        expect(result[:photo_sent]).to be(true)
        expect(hers.visible_messages).to include(photo)
        expect(hers.byte_messages).not_to include(photo)
        expect(photo.reload.files.count).to eq(1)
      end

      # The note still goes; what must not happen is claiming a picture went.
      it "still sends the note, and admits it, when there's no recent picture" do
        frame!(at: 2.hours.ago)
        result = run(:message_partner, { to: her, message: "someone out front", with_photo: true })

        expect(result[:photo_sent]).to be(false)
        expect(BuddyRelay.last.body).to eq("someone out front")
      end

      it "sends nothing extra when the note isn't about a picture" do
        frame!

        expect { run(:message_partner, { to: her, message: "he fed the dog" }) }
          .not_to change(ByteMessageShare, :count)
      end
    end
  end

  # A relay attribution in the reply with no relay behind it means nothing
  # reached the partner, so an uncalled relay has to read as a claim.
  describe Buddy::GPT::Turn do
    it "reads \"Sent.\"-style replies and the relay attribution as claims, and an offer as none" do
      [
        "Sent. 😅",
        "Passed it along to Chelsea.",
        "Told her already.",
        "She's in the loop now.",
        "[you passed this along to Moss] Rude.",
        "Sent. 😅\n\n[you passed this along to Moss] Rude. Byte took away my formatting!",
      ].each { |text| expect(described_class.unbacked_claim(text)).to eq(:claim), text }

      expect(described_class.unbacked_claim("Want me to send that along?")).to be_nil
      expect(described_class.unbacked_claim("Let me know and I'll tell her.")).to be_nil
    end
  end

  # A relayed question can be answered whenever the partner gets to it, so its
  # card carries no fuse; everything else keeps ByteAction's default.
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

    # The client greys stale rows off `action_expires_at` and nothing else, so
    # the card has to say there is none.
    it "leaves the question open with no fuse, still active a day later, and tells the client", :aggregate_failures do
      relay  = ask!
      action = ByteAction.find_by(tool_name: "buddy_relay_answer", user_id: relay.to_user_id)

      expect(action.expires_at).to be_nil
      travel_to(25.minutes.from_now) { expect(action.reload).to be_pending }
      travel_to(1.day.from_now) { expect(ByteAction.active).to include(action) }

      card = partner_convo.byte_messages.where("metadata->>'tool_name' = 'buddy_relay_answer'").last
      expect(card.metadata).to have_key("action_expires_at")
      expect(card.metadata["action_expires_at"]).to be_nil
    end

    # A caller-supplied nil is indistinguishable from silence under `||=`, so
    # an explicit nil still gets the default.
    it "keeps the default fuse on everything else, even against an explicit nil, and honours a given one" do
      action = ->(**attrs) {
        ByteAction.create!(
          user: asker, byte_conversation: asker_convo, kind: :custom,
          tool_name: "something_else", buttons: [], multi_select: false, **attrs
        )
      }

      expect(action.call.expires_at).to be_within(5.seconds).of(ByteAction::DEFAULT_TTL.from_now)
      expect(action.call(expires_at: nil).expires_at).to be_present
      expect(action.call(expires_at: 2.hours.from_now).expires_at).to be_within(5.seconds).of(2.hours.from_now)
    end
  end
end
