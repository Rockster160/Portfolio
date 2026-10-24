require "rails_helper"

RSpec.describe Jil::Methods::Buddy do
  describe "the method" do
    let(:owner)    { User.me }
    let(:asker)    { FactoryBot.create(:user) }
    let!(:owner_convo) { owner.byte_conversations.create!(mode: :buddy, name: "Byte") }
    let!(:asker_convo) { asker.byte_conversations.create!(mode: :buddy, name: "Suki") }

    # A 1x1 JPEG is the smallest thing that clears the FF D8 check and still
    # decodes, which is all any of this cares about.
    let(:jpeg_b64) {
      Base64.strict_encode64(
        ["ffd8ffe000104a46494600010100000100010000ffdb004300ff" \
         "c00011080001000101011100ffc40014000100000000000000000000000000000000" \
         "09ffc40014100100000000000000000000000000000000ffda000c03010002110311" \
         "003f00bfffd9"].pack("H*"),
      )
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
    end

    def run(code, auth: nil, auth_id: nil)
      Jil::Executor.call(owner, code, {}, auth: auth, auth_id: auth_id)
    end

    it "validates Buddy.say / Buddy.prompt / Buddy.photo Jil" do
      code = <<~'JIL'
        a1 = Buddy.say("Trash goes out tonight")::Boolean
        a2 = Buddy.prompt("remind them trash night is tonight, keep it light")::Boolean
        img = String.new("abc")::String
        a3 = Buddy.photo(img, "Front door")::Boolean
        a4 = Buddy.checklist("Before Bed", "Still to do:")::Numeric
      JIL
      expect { Jil::Validator.validate!(code) }.not_to raise_error
    end

    describe "#checklist" do
      let!(:list) { create(:list, name: "Before Bed", user: owner) }

      it "puts the list up as a box per item and answers with the count" do
        create(:list_item, list: list, name: "Lock the back door")
        create(:list_item, list: list, name: "Start the dishwasher")

        ctx = run(<<~'JIL')
          boxes = Buddy.checklist("Before Bed", "Still to do before bed:")::Numeric
        JIL

        expect(ctx.ctx[:vars][:boxes][:value]).to eq(2)
        action = ByteAction.where(user: owner, tool_name: "buddy_proposals").last
        expect(action.buttons.pluck("label")).to match_array(["Lock the back door", "Start the dishwasher"])
        expect(owner_convo.byte_messages.last.body).to eq("Still to do before bed:")
      end

      # Nothing left to do is not a thing to buzz someone about, and the caller
      # is better placed than this is to decide whether it deserves words.
      it "posts nothing and answers 0 on an empty list" do
        expect {
          ctx = run(<<~'JIL')
            boxes = Buddy.checklist("Before Bed", "Still to do before bed:")::Numeric
          JIL
          expect(ctx.ctx[:vars][:boxes][:value]).to eq(0)
        }.not_to change(ByteMessage, :count)
      end

      it "answers 0 for a list that isn't theirs" do
        ctx = run(<<~'JIL')
          boxes = Buddy.checklist("Some Other List", "Still to do:")::Numeric
        JIL

        expect(ctx.ctx[:vars][:boxes][:value]).to eq(0)
      end
    end

    describe "#say" do
      it "hands CompanionDelivery a verbatim inbound message + push" do
        convo = double("conversation")
        allow(Buddy::CompanionRelay).to receive(:conversation_for).with(owner).and_return(convo)

        expect(Buddy::CompanionDelivery).to receive(:deliver_plain).with(
          user:         owner,
          conversation: convo,
          text:         "Trash goes out tonight",
          files:        [],
          metadata:     { kind: :buddy, source: :jil },
          push_title:   "Trash goes out tonight",
        )

        ctx = run(<<~'JIL')
          out = Buddy.say("Trash goes out tonight")::Boolean
        JIL
        expect(ctx.ctx[:vars][:out][:value]).to be(true)
      end

      it "returns false and delivers nothing on a blank message" do
        expect(Buddy::CompanionDelivery).not_to receive(:deliver_plain)

        ctx = run(<<~'JIL')
          out = Buddy.say("   ")::Boolean
        JIL
        expect(ctx.ctx[:vars][:out][:value]).to be(false)
      end

      it "drops the text into the owner's Buddy thread with no model turn" do
        expect(BuddyDeliverWorker).not_to receive(:perform_async)

        run(<<~'JIL')
          ok = Buddy.say("The bins go out tonight")::Boolean
        JIL

        message = owner_convo.byte_messages.last
        expect(message.body).to eq("The bins go out tonight")
        expect(message.direction).to eq("inbound")
        expect(message.metadata).to include("kind" => "buddy", "source" => "jil")
      end
    end

    describe "#prompt" do
      it "seeds an in-character turn tagged buddy_trigger" do
        convo = double("conversation")
        allow(Buddy::CompanionRelay).to receive(:conversation_for).with(owner).and_return(convo)

        expect(Buddy::CompanionDelivery).to receive(:deliver_prompt).with(
          user:         owner,
          conversation: convo,
          seed:         "let them know the wash is done",
          metadata:     { kind: :buddy_trigger, hidden: true, source: :jil },
        )

        run(<<~'JIL')
          p1 = Buddy.prompt("let them know the wash is done")::Boolean
        JIL
      end
    end

    describe "#photo" do
      it "posts the decoded frame as an attachment" do
        run(<<~JIL)
          img = String.new("#{jpeg_b64}")::String
          ok = Buddy.photo(img, "Front door")::Boolean
        JIL

        message = owner_convo.byte_messages.last
        expect(message.body).to eq("Front door")
        expect(message.files.attachments.size).to eq(1)
        expect(message.files.first.content_type).to eq("image/jpeg")
      end

      it "posts the picture on its own when there's no caption" do
        run(<<~JIL)
          img = String.new("#{jpeg_b64}")::String
          ok = Buddy.photo(img, "")::Boolean
        JIL

        expect(owner_convo.byte_messages.last.files.attachments.size).to eq(1)
        expect(WebPushNotifications).to have_received(:send_to_byte).with(
          hash_including(title: "📷 New photo"),
        )
      end

      # HASS answers 200 with an empty body when a camera is dead. Storing that
      # puts a broken image in the thread, which reads as an answer.
      it "returns false and posts nothing when the bytes aren't an image" do
        expect {
          run(<<~'JIL')
            img = String.new("bm90LWFuLWltYWdl")::String
            ok = Buddy.photo(img, "Front door")::Boolean
          JIL
        }.not_to change(ByteMessage, :count)
      end

      it "returns false and posts nothing on an empty frame" do
        expect {
          run(<<~'JIL')
            img = String.new("")::String
            ok = Buddy.photo(img, "Front door")::Boolean
          JIL
        }.not_to change(ByteMessage, :count)
      end
    end

    # The reason this file exists. A task shared with Chelsea RUNS AS ROCCO — that
    # is how it reaches his HASS credentials — so every delivery in it defaulted
    # to his thread. Her asking for the doorbell put the picture on his phone and
    # left her conversation empty.
    describe "who the message goes to" do
      it "answers the person who asked, not the person who owns the task" do
        run(<<~JIL, auth: :buddy, auth_id: asker.id)
          img = String.new("#{jpeg_b64}")::String
          ok = Buddy.photo(img, "Front door")::Boolean
        JIL

        expect(asker_convo.byte_messages.count).to eq(1)
        expect(owner_convo.byte_messages.count).to eq(0)
        expect(asker_convo.byte_messages.last.files.attachments.size).to eq(1)
      end

      it "routes a plain say the same way" do
        run(<<~'JIL', auth: :buddy, auth_id: asker.id)
          ok = Buddy.say("Nothing on the driveway")::Boolean
        JIL

        expect(asker_convo.byte_messages.last.body).to eq("Nothing on the driveway")
        expect(owner_convo.byte_messages.count).to eq(0)
      end

      # Cron, a listener, a `tell:` — nobody asked, so the owner is the answer.
      it "falls back to the owner when nothing fired it on anyone's behalf" do
        run(<<~'JIL', auth: :cron)
          ok = Buddy.say("The bins go out tonight")::Boolean
        JIL

        expect(owner_convo.byte_messages.last.body).to eq("The bins go out tonight")
        expect(asker_convo.byte_messages.count).to eq(0)
      end

      it "falls back to the owner when the acting user is gone" do
        run(<<~'JIL', auth: :buddy, auth_id: 0)
          ok = Buddy.say("The bins go out tonight")::Boolean
        JIL

        expect(owner_convo.byte_messages.last.body).to eq("The bins go out tonight")
      end
    end
  end

  # Buddy.sayEvent — the same fixed message as Buddy.say, but addressed to
  # whoever the EVENT belongs to rather than to whoever's task is running.
  #
  # The travel alerts are why: they're computed by Rocco's tasks (his car, his
  # address book) and may be about an event on somebody else's calendar, where
  # "leave by 5:30" is no use to the person not going.
  describe "saying an event" do
    let(:owner)   { User.me }
    let(:partner) { create(:user, phone: "5550000201") }
    let!(:owner_convo)   { owner.byte_conversations.create!(mode: :buddy, name: "Byte") }
    let!(:partner_convo) { partner.byte_conversations.create!(mode: :buddy, name: "Moss") }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(::AgendaTravelChainSyncWorker).to receive(:perform_async).and_return(nil)
      allow(::Jil).to receive(:trigger)
    end

    def event_on(agenda)
      agenda.agenda_items.create!(
        kind:     :event,
        name:     "Dinner",
        start_at: 1.day.from_now,
        end_at:   1.day.from_now + 1.hour,
        location: "Ruth's Chris",
      )
    end

    def say_event(item, message, as: owner)
      Jil::Executor.call(as, <<~JIL, {})
        told = Buddy.sayEvent(#{item.id}, "#{message}")::Numeric
      JIL
    end

    def bodies_for(convo)
      convo.byte_messages.reload.map(&:body)
    end

    it "validates as Jil" do
      code = <<~'JIL'
        eid = Numeric.new(4)::Numeric
        told = Buddy.sayEvent(eid, "Leave by 5:30 to make dinner")::Numeric
      JIL
      expect { Jil::Validator.validate!(code) }.not_to raise_error
    end

    describe "a personal calendar" do
      let(:agenda) { owner.agendas.create!(name: "Work") }

      it "tells the owner and returns the count" do
        ctx = say_event(event_on(agenda), "Leave by 5:30")

        expect(ctx.ctx[:vars][:told][:value]).to eq(1)
        expect(bodies_for(owner_convo)).to eq(["Leave by 5:30"])
      end

      # The rule the user asked for in as many words: personal calendars reach
      # only the relevant person, even when they're shared.
      it "still tells only the owner when it's shared with an editor" do
        agenda.agenda_shares.create!(user: partner, permission: :editor)
        say_event(event_on(agenda), "Leave by 5:30")

        expect(bodies_for(owner_convo)).to eq(["Leave by 5:30"])
        expect(bodies_for(partner_convo)).to be_empty
      end
    end

    describe "a joint calendar" do
      let(:agenda) { owner.agendas.create!(name: "Ours") }

      before { agenda.agenda_shares.create!(user: partner, permission: :owner) }

      it "tells everyone whose calendar it is" do
        ctx = say_event(event_on(agenda), "Leave by 5:30")

        expect(ctx.ctx[:vars][:told][:value]).to eq(2)
        expect(bodies_for(owner_convo)).to eq(["Leave by 5:30"])
        expect(bodies_for(partner_convo)).to eq(["Leave by 5:30"])
      end
    end

    # The reverse case: a calendar shared IN to the person whose task is
    # computing the drive. The alert is about her day, so it goes to her.
    describe "somebody else's calendar, shared in" do
      let(:agenda) { partner.agendas.create!(name: "Hers") }

      before { agenda.agenda_shares.create!(user: owner, permission: :viewer) }

      it "tells its owner, not the person running the task" do
        say_event(event_on(agenda), "Leave by 5:30")

        expect(bodies_for(partner_convo)).to eq(["Leave by 5:30"])
        expect(bodies_for(owner_convo)).to be_empty
      end
    end

    describe "nobody to tell" do
      let(:agenda) { owner.agendas.create!(name: "Work") }

      # Missing beats wrong: a stale trigger for a deleted event has no audience
      # to infer, so it reaches nobody and says so.
      it "returns 0 for an event that can't be resolved" do
        ctx = Jil::Executor.call(owner, <<~'JIL', {})
          told = Buddy.sayEvent(0, "Leave by 5:30")::Numeric
        JIL

        expect(ctx.ctx[:vars][:told][:value]).to eq(0)
        expect(ByteMessage.count).to eq(0)
      end

      it "returns 0 on a blank message" do
        ctx = say_event(event_on(agenda), "   ")

        expect(ctx.ctx[:vars][:told][:value]).to eq(0)
        expect(ByteMessage.count).to eq(0)
      end

      # No companion gets spun up by a notification — same gate as
      # AgendaNotifyOthersWorker.
      it "skips a co-owner who has never opened Buddy" do
        stranger = create(:user, phone: "5550000202")
        agenda.agenda_shares.create!(user: stranger, permission: :owner)
        ctx = say_event(event_on(agenda), "Leave by 5:30")

        expect(ctx.ctx[:vars][:told][:value]).to eq(1)
        expect(stranger.byte_conversations.count).to eq(0)
      end

      it "returns 0 for an event on a calendar the task can't see" do
        hidden = partner.agendas.create!(name: "Private")
        ctx = say_event(event_on(hidden), "Leave by 5:30")

        expect(ctx.ctx[:vars][:told][:value]).to eq(0)
        expect(ByteMessage.count).to eq(0)
      end
    end

    it "lands verbatim, with no model turn" do
      agenda = owner.agendas.create!(name: "Work")
      expect(BuddyDeliverWorker).not_to receive(:perform_async)

      say_event(event_on(agenda), "Leave by 5:30")

      message = owner_convo.byte_messages.last
      expect(message.direction).to eq("inbound")
      expect(message.metadata).to include("kind" => "buddy", "source" => "jil")
    end
  end

  # Something OUTSTANDING, rather than something that happened. The thing that
  # notices and the thing that clears are rarely the same trigger, so the key is
  # the whole of the coupling between them.
  describe "#alert / #resolve" do
    let(:owner) { User.me }
    let!(:owner_convo) { owner.byte_conversations.create!(mode: :buddy, name: "Byte") }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
    end

    it "validates" do
      code = <<~'JIL'
        a1 = Buddy.alert("laundry-gate", "The laundry gate is open")::Boolean
        a2 = Buddy.resolve("laundry-gate", "Laundry gate is shut")::Boolean
      JIL

      expect { Jil::Validator.validate!(code) }.not_to raise_error
    end

    it "opens one, holds it to a single bubble, and closes it where it stands" do
      ctx = Jil::Executor.call(owner, <<~'JIL', {})
        opened = Buddy.alert("laundry-gate", "The laundry gate is open")::Boolean
        again = Buddy.alert("laundry-gate", "The laundry gate is still open")::Boolean
        closed = Buddy.resolve("laundry-gate", "Laundry gate is shut")::Boolean
        nothing = Buddy.resolve("laundry-gate", "Laundry gate is shut")::Boolean
      JIL

      expect(ctx.ctx[:vars][:opened][:value]).to be(true)
      expect(ctx.ctx[:vars][:again][:value]).to be(true)
      expect(ctx.ctx[:vars][:closed][:value]).to be(true)
      # Nothing was open by then, which is how a scheduled check tells that it
      # cleared something from that it was already fine.
      expect(ctx.ctx[:vars][:nothing][:value]).to be(false)

      expect(owner_convo.byte_messages.count).to eq(1)
      message = owner_convo.byte_messages.last
      expect(message.body).to eq("Laundry gate is shut")
      expect(message.metadata["kind"]).to eq("alert")
      expect(message.metadata.dig("alert", "status")).to eq("resolved")
      expect(message.metadata.dig("alert", "count")).to eq(2)
    end

    it "answers false when there is nothing to say" do
      ctx = Jil::Executor.call(owner, <<~'JIL', {})
        blank = Buddy.alert("   ", "The laundry gate is open")::Boolean
        wordless = Buddy.alert("laundry-gate", "  ")::Boolean
      JIL

      expect(ctx.ctx[:vars][:blank][:value]).to be(false)
      expect(ctx.ctx[:vars][:wordless][:value]).to be(false)
      expect(ByteMessage.count).to eq(0)
    end

    # A shared task runs as its OWNER, and an alert raised on somebody else's
    # behalf has to land in THEIR thread — same rule every other method here
    # follows through `recipient`.
    it "speaks to whoever asked, not to whoever owns the task" do
      asker = create(:user)
      asker.byte_conversations.create!(mode: :buddy, name: "Suki")

      Jil::Executor.call(owner, <<~'JIL', {}, auth: :buddy, auth_id: asker.id)
        opened = Buddy.alert("laundry-gate", "The laundry gate is open")::Boolean
      JIL

      expect(BuddyAlert.open_for(asker, "laundry-gate")).to be_present
      expect(owner_convo.byte_messages.count).to eq(0)
    end

    # Rocco: "Let's send an alert to Moss/Chelsea for the Laundry Gate as well."
    #
    # An open gate is open for whoever walks past it, and the person who can
    # shut it is whoever happens to be home - so a household condition is a real
    # shape rather than a special case for this one sensor.
    describe "who it is for" do
      let(:housemate) { create(:user, username: "sandboxchelsea") }
      let(:house) { owner.reload.chore_household }

      before do
        share_chore_household!(owner, housemate)
        housemate.byte_conversations.create!(mode: :buddy, name: "Moss")
      end

      def run(code)
        Jil::Executor.call(owner, code, {})
      end

      it "gives everyone in the house their own bubble under the same key" do
        ctx = run(<<~'JIL')
          opened = Buddy.alert("laundry-gate", "The laundry gate is open", {
            openedWho = Keyword.who("house")::String
          })::Boolean
        JIL

        expect(ctx.ctx[:vars][:opened][:value]).to be(true)
        expect(BuddyAlert.open_for(owner, "laundry-gate")).to be_present
        expect(BuddyAlert.open_for(housemate, "laundry-gate")).to be_present
      end

      # The point of doing it under one key: whoever shuts the gate clears it
      # for both of them, and nobody is left looking at a warning about
      # something already dealt with.
      it "clears every one of them at once" do
        ctx = run(<<~'JIL')
          opened = Buddy.alert("laundry-gate", "The laundry gate is open", {
            openedWho = Keyword.who("house")::String
          })::Boolean
          closed = Buddy.resolve("laundry-gate", "Laundry gate is shut", "house")::Boolean
        JIL

        expect(ctx.ctx[:vars][:closed][:value]).to be(true)
        expect(BuddyAlert.open_for(owner, "laundry-gate")).to be_nil
        expect(BuddyAlert.open_for(housemate, "laundry-gate")).to be_nil
        expect(housemate.byte_messages.last.body).to eq("Laundry gate is shut")
      end

      # The shape this was actually built for: the two people a condition
      # concerns, not the whole roster. A housemate with nothing to do with the
      # dog doesn't need a warning about the dog, and the way that goes wrong is
      # an alert somebody learns to swipe away.
      it "takes a list, so it can be the two people it concerns" do
        outsider = create(:user, username: "sandboxlodger")
        share_chore_household!(owner, outsider)
        outsider.byte_conversations.create!(mode: :buddy, name: "Glimmer")

        run(<<~'JIL')
          opened = Buddy.alert("laundry-gate", "The laundry gate is open", {
            openedWho = Keyword.who("me")::String
            openedChelsea = Keyword.who("Chelsea")::String
          })::Boolean
        JIL

        expect(BuddyAlert.open_for(owner, "laundry-gate")).to be_present
        expect(BuddyAlert.open_for(housemate, "laundry-gate")).to be_present
        expect(BuddyAlert.open_for(outsider, "laundry-gate")).to be_nil
      end

      it "reaches one person by name" do
        run(<<~'JIL')
          opened = Buddy.alert("laundry-gate", "The laundry gate is open", {
            openedWho = Keyword.who("chelsea")::String
          })::Boolean
        JIL

        expect(BuddyAlert.open_for(housemate, "laundry-gate")).to be_present
        expect(BuddyAlert.open_for(owner, "laundry-gate")).to be_nil
      end

      # Reaching the wrong person is worse than reaching nobody, so a name that
      # matches nobody is a false rather than a fallback onto the owner.
      it "reaches nobody at all for a name nobody goes by" do
        ctx = run(<<~'JIL')
          opened = Buddy.alert("laundry-gate", "The laundry gate is open", {
            openedWho = Keyword.who("nigel")::String
          })::Boolean
        JIL

        expect(ctx.ctx[:vars][:opened][:value]).to be(false)
        expect(BuddyAlert.count).to eq(0)
      end

      # Nobody gets a companion spun up for them by a notification - same gate
      # `audience` uses for the travel alerts.
      it "skips a housemate with no companion thread" do
        outsider = create(:user, username: "sandboxlodger")
        share_chore_household!(owner, outsider)

        run(<<~'JIL')
          opened = Buddy.alert("laundry-gate", "The laundry gate is open", {
            openedWho = Keyword.who("house")::String
          })::Boolean
        JIL

        expect(BuddyAlert.open_for(outsider, "laundry-gate")).to be_nil
      end

      it "still means just them when the argument is left off" do
        run(<<~'JIL')
          opened = Buddy.alert("laundry-gate", "The laundry gate is open")::Boolean
        JIL

        expect(BuddyAlert.open_for(owner, "laundry-gate")).to be_present
        expect(BuddyAlert.open_for(housemate, "laundry-gate")).to be_nil
      end

      it "validates with the audience given" do
        code = <<~'JIL'
          a1 = Buddy.alert("laundry-gate", "The laundry gate is open", {
            a1Who = Keyword.who("house")::String
          })::Boolean
          a2 = Buddy.resolve("laundry-gate", "Laundry gate is shut", "house")::Boolean
        JIL

        expect { Jil::Validator.validate!(code) }.not_to raise_error
      end

      # A question with buttons for the two people it concerns. Each press
      # fires a trigger; one press, or the thing happening by itself, settles
      # every copy.
      describe "#message / #button / #resolveMessage" do
        let(:send_code) {
          <<~'JIL'
            closeData = Hash.new({
              kDir = Keyval.new("direction", "close")::Keyval
            })::Hash
            sent = Buddy.message("door-open", "The door is open!", {
              toMe = Keyword.who("me")::String
              toChelsea = Keyword.who("Chelsea")::String
              closeBtn = Buddy.button("Close the door", {
                closeTrigger = Keyword.trigger("door")::String
                closeWith = Keyword.data(closeData)::Hash
                closeColor = Keyword.color("#E25822")::String
              })::Hash
              leaveBtn = Buddy.button("Leave it", {
                leaveTrigger = Keyword.trigger("door")::String
                leaveSaid = Keyword.resolved("Leaving it open")::String
              })::Hash
            })::Numeric
          JIL
        }

        before { allow(Jil).to receive(:trigger).and_call_original }

        def action_for(user)
          ByteAction.find_by(user: user, tool_name: Buddy::MessageButtons::TOOL_NAME)
        end

        def press(user, id)
          action = action_for(user)
          button = Buddy::MessageButtons.button_for(action, id)
          action.apply_decision!(value: id, source: :user)
          Buddy::MessageButtons.tapped!(action, button, user)
        end

        it "validates" do
          code = send_code + <<~'JIL'
            done = Buddy.resolveMessage("door-open", "The door is shut", "me, Chelsea")::Boolean
          JIL

          expect { Jil::Validator.validate!(code) }.not_to raise_error
        end

        it "sends each of them a message with the buttons under it" do
          ctx = run(send_code)

          expect(ctx.ctx[:vars][:sent][:value]).to eq(2)
          [owner, housemate].each do |user|
            meta = action_for(user).byte_message.metadata
            expect(meta).to include("tool_name" => Buddy::MessageButtons::TOOL_NAME, "action_state" => "pending")
            expect(meta["buttons"]).to eq([
              { "id" => 1, "label" => "Close the door", "color" => "#e25822" },
              { "id" => 2, "label" => "Leave it" },
            ])
          end
          expect(BuddyAlert.count).to eq(0)
        end

        it "fires the trigger as the owner and settles both copies when either presses" do
          run(send_code)
          press(housemate, 1)

          expect(Jil).to have_received(:trigger).with(
            owner, "door", { "direction" => "close", "pressed_by" => housemate.first_name }, auth: :trigger,
          )
          expect(action_for(owner).reload).to be_decided
          expect(action_for(owner).byte_message.reload.metadata["buttons_outcome"])
            .to eq("#{housemate.first_name} pressed \"Close the door\"")
          expect(action_for(housemate).byte_message.reload.metadata["buttons_outcome"])
            .to eq("You pressed \"Close the door\"")
        end

        it "shows a button's own words when it gives them" do
          run(send_code)
          press(owner, 2)

          expect(action_for(housemate).byte_message.reload.metadata["buttons_outcome"]).to eq("Leaving it open")
        end

        it "leaves the other copy waiting when the button doesn't resolve" do
          run(send_code.sub('leaveSaid = Keyword.resolved("Leaving it open")::String', 'leaveKeep = Keyword.resolve(false)::Boolean'))
          press(owner, 2)

          expect(action_for(housemate).reload).to be_pending
        end

        it "settles every copy from another task" do
          run(send_code)
          ctx = run('done = Buddy.resolveMessage("door-open", "The door is closing", "me, Chelsea")::Boolean')

          expect(ctx.ctx[:vars][:done][:value]).to be(true)
          expect(action_for(housemate).reload).to be_decided
          expect(action_for(housemate).byte_message.reload.metadata["buttons_outcome"]).to eq("The door is closing")
          expect(Jil).not_to have_received(:trigger).with(owner, "door", anything)
        end

        it "replaces the copy still waiting when it's sent again" do
          run(send_code)
          first = action_for(owner)
          run(send_code)

          expect(first.reload).to be_decided
          expect(ByteAction.pending.where(user: owner, tool_name: Buddy::MessageButtons::TOOL_NAME).count).to eq(1)
        end

        it "fails the task for a button with nothing to fire" do
          ctx = run(send_code.sub('closeTrigger = Keyword.trigger("door")::String', ""))

          expect(ctx.ctx[:error]).to match(/"Close the door" button needs a trigger/)
          expect(ByteMessage.where(byte_conversation: owner_convo).count).to eq(0)
        end
      end
    end
  end

  # The hero's OTHER notice - a chip pinned top-right, not the alert bar. A
  # standing marker on the hero itself while a condition is true, gone the
  # moment it isn't. Backed by BackgroundProcess, same rows the process chips
  # ride on.
  describe "#miniAlert / #clearMiniAlert" do
    let(:owner) { User.me }

    before { allow(MonitorChannel).to receive(:broadcast_to) }

    def run(code, auth: nil, auth_id: nil)
      Jil::Executor.call(owner, code, {}, auth: auth, auth_id: auth_id)
    end

    it "validates" do
      code = <<~'JIL'
        a1 = Buddy.miniAlert("laundry-gate", "Laundry gate open")::Boolean
        a2 = Buddy.clearMiniAlert("laundry-gate")::Boolean
      JIL

      expect { Jil::Validator.validate!(code) }.not_to raise_error
    end

    it "puts up one waiting chip, holds it to a single row, and clears it" do
      ctx = run(<<~'JIL')
        up = Buddy.miniAlert("laundry-gate", "Laundry gate open", "dog is loose")::Boolean
        again = Buddy.miniAlert("laundry-gate", "Laundry gate open", "dog is loose")::Boolean
        gone = Buddy.clearMiniAlert("laundry-gate")::Boolean
        nothing = Buddy.clearMiniAlert("laundry-gate")::Boolean
      JIL

      expect(ctx.ctx[:vars][:up][:value]).to be(true)
      expect(ctx.ctx[:vars][:again][:value]).to be(true)
      expect(ctx.ctx[:vars][:gone][:value]).to be(true)
      # Nothing was live by then - the way a scheduled re-check tells "I just
      # cleared one" from "already fine".
      expect(ctx.ctx[:vars][:nothing][:value]).to be(false)

      # One row, settled rather than deleted, carrying its last words.
      expect(BackgroundProcess.where(user: owner, key: "laundry-gate").count).to eq(1)
      expect(BackgroundProcess.live_find(owner, "laundry-gate")).to be_nil
      chip = BackgroundProcess.where(user: owner, key: "laundry-gate").last
      expect(chip.name).to eq("Laundry gate open")
      expect(chip.detail).to eq("dog is loose")
      expect(chip.source).to eq("jil")
    end

    # A chip for a state someone is in: coloured, ahead of the rest, and its ×
    # fires a trigger so letting go of it ends the state.
    it "takes a colour, a pin and a trigger for its ×" do
      run(<<~'JIL')
        better = Hash.keyval("action", "better")::Hash
        up = Buddy.miniAlert("sick", "Sick", "since Thursday", "", {
          c = Keyword.color("green")::String
          p = Keyword.pinned(true)::Boolean
          t = Keyword.trigger("sick")::String
          d = Keyword.data(better)::Hash
          tp = Keyword.tap("sick")::String
          td = Keyword.tapData(better)::Hash
        })::Boolean
      JIL

      chip = BackgroundProcess.live_find(owner, "sick")
      expect(chip.serialize).to include(color: "#3fb950", pinned: true, tappable: true)
      expect(chip.metadata).to include(
        "trigger" => "sick", "data" => { "action" => "better" }, "owner_id" => owner.id,
        "tap" => "sick", "tap_data" => { "action" => "better" }
      )
    end

    it "takes the block straight after the label too" do
      run(<<~'JIL')
        up = Buddy.miniAlert("sick", "Sick", {
          c = Keyword.color("#112233")::String
        })::Boolean
      JIL

      chip = BackgroundProcess.live_find(owner, "sick")
      expect(chip.detail).to be_nil
      expect(chip.metadata["color"]).to eq("#112233")
    end

    it "lets go of a chip from code without firing its trigger" do
      allow(Jil).to receive(:trigger)
      run(<<~'JIL')
        up = Buddy.miniAlert("sick", "Sick", "", "", {
          t = Keyword.trigger("sick")::String
        })::Boolean
        gone = Buddy.clearMiniAlert("sick")::Boolean
      JIL

      expect(BackgroundProcess.live_find(owner, "sick")).to be_nil
      expect(Jil).not_to have_received(:trigger)
    end

    # waiting/failed are exempt from the stale + age-out sweeps, so a standing
    # condition stays on the strip until something clears it.
    it "raises the chip as waiting, not running" do
      run(<<~'JIL')
        up = Buddy.miniAlert("laundry-gate", "Laundry gate open")::Boolean
      JIL

      expect(BackgroundProcess.live_find(owner, "laundry-gate")).to be_waiting
    end

    # Same recipient rule as alert: a shared task runs as its owner, but a chip
    # raised on somebody else's behalf belongs on THEIR hero.
    it "puts the chip on whoever asked, not whoever owns the task" do
      asker = create(:user)

      run(<<~'JIL', auth: :buddy, auth_id: asker.id)
        up = Buddy.miniAlert("laundry-gate", "Laundry gate open")::Boolean
      JIL

      expect(BackgroundProcess.live_find(asker, "laundry-gate")).to be_present
      expect(BackgroundProcess.live_find(owner, "laundry-gate")).to be_nil
    end

    # A board's task button passes the board it was pressed on, so the loop the
    # task starts shows on that board and no other.
    it "puts a rotation on the board whose button ran the task" do
      code = <<~JIL
        r = Buddy.rotate("laundry", "Rotate Laundry", 75, "minutes", "Rotated", "", "")::Boolean
      JIL
      Sidekiq::Testing.fake! { Jil::Executor.call(owner, code, { "execute" => true, "board_id" => 42 }) }

      timer = Buddy::RotationTimer.live_timer(owner, "laundry")
      expect(Buddy::Timers.board_id(timer)).to eq(42)
    end

    it "starts a timer on a named board, or on any board watching its groups" do
      board = owner.byte_conversations.create!(mode: :buddy, name: "Kitchen", metadata: { "board" => true })
      code = <<~JIL
        a = Buddy.timer(10, "minutes", {
          aLabel = Keyword.label("Pasta")::String
          aBoard = Keyword.board("Kitchen")::String
        })::Boolean
        b = Buddy.timer(5, "minutes", {
          bLabel = Keyword.label("Tea")::String
          bHome = Keyword.groups("Home")::String
          bWhisper = Keyword.groups("Whisper")::String
        })::Boolean
      JIL
      Sidekiq::Testing.fake! { Jil::Executor.call(owner, code) }

      pasta = owner.timers.find_by(name: "Pasta")
      tea   = owner.timers.find_by(name: "Tea")
      expect(pasta.duration_ms).to eq(600_000)
      expect(Buddy::Timers.board_id(pasta)).to eq(board.id)
      expect(Buddy::Timers.groups(tea)).to eq(%w[Home Whisper])
    end

    it "validates Buddy.timer Jil" do
      expect {
        Jil::Validator.validate!(
          <<~JIL,
            a = Buddy.timer(10, "minutes", {
              aLabel = Keyword.label("Pasta")::String
              aGroups = Keyword.groups("Home")::String
            })::Boolean
          JIL
        )
      }.not_to raise_error
    end

    it "takes its optional settings as a block, strength included, and leaves out what it does not use" do
      Jil::Validator.validate!(
        <<~JIL,
          a = Buddy.dream("food", "Foodies!", {
            aGroups = Keyword.groups("Whisper")::String
            aFace = Keyword.face("thinking")::String
            aStrength = Keyword.strength(45)::Numeric
          })::Boolean
          b = Buddy.boardAlert("gate", "Gate open", {
            bGroups = Keyword.groups("Whisper")::String
            bFace = Keyword.face("pounce")::String
          })::Boolean
        JIL
      )
      run(<<~JIL)
        a = Buddy.dream("food", "Foodies!", {
          aGroups = Keyword.groups("Whisper")::String
          aFace = Keyword.face("thinking")::String
          aStrength = Keyword.strength(45)::Numeric
        })::Boolean
        b = Buddy.boardAlert("gate", "Gate open", {
          bGroups = Keyword.groups("Whisper")::String
          bFace = Keyword.face("pounce")::String
        })::Boolean
      JIL

      expect(BuddyAlert.open_for(owner, "food").strength).to eq(45)
      expect(BuddyAlert.open_for(owner, "gate").strength).to eq(Buddy::FaceStrength::ALERT)
    end

    it "holds a mood with no words, from the axes given, until it is resolved" do
      code = <<~JIL
        a = Buddy.mood("busy", {
          aGroups = Keyword.groups("Whisper")::String
          aWarmth = Keyword.warmth(0.7)::Slider
          aPlay = Keyword.play(0.5)::Slider
          aStrain = Keyword.strain(1.4)::Slider
          aReach = Keyword.reach(0.1)::Slider
          aStrength = Keyword.strength(60)::Numeric
        })::Boolean
      JIL
      Jil::Validator.validate!(code)
      run(code)

      held = BuddyAlert.open_for(owner, "busy")
      expect(held.body).to eq("")
      expect(held).to be_board_only
      expect(held.mood).to eq("warmth" => 0.7, "play" => 0.5, "strain" => 1.0, "reach" => 0.1)
      expect(held.strength).to eq(60)
      expect(held.strip_wire["faces"]).to include("byte", "tiko", "moss")

      run(%(a = Buddy.resolve("busy", "", "")::Boolean))
      expect(BuddyAlert.open_for(owner, "busy")).to be_nil
    end

    it "takes any face by name, and notes one no pet has without failing" do
      ran = run(<<~JIL)
        a = Buddy.boardAlert("gate", "Gate open", {
          aFace = Keyword.face("eager")::String
        })::Boolean
        b = Buddy.mood("typo", {
          bGroups = Keyword.groups("Whisper")::String
          bFace = Keyword.face("eagre")::String
          bStrength = Keyword.strength(30)::Numeric
        })::Boolean
      JIL

      expect(ran.ctx[:error]).to be_blank
      expect(ran.ctx[:output]).to include(%(No pet has a face called "eagre" - they keep to their own feelings))
      gate = BuddyAlert.open_for(owner, "gate")
      expect(gate.face_for(:byte)).to eq("eager")
      expect(gate.face_for(:tiko)).to be_nil
      typo = BuddyAlert.open_for(owner, "typo")
      expect(typo).to be_look_only
      expect(typo.faces).to eq({})
    end

    it "wears the face where a pet has it, and the mood where it doesn't" do
      run(<<~JIL)
        a = Buddy.mood("busy", {
          aFace = Keyword.face("nerd")::String
          aWarmth = Keyword.warmth(0.55)::Slider
          aPlay = Keyword.play(0.05)::Slider
          aWeight = Keyword.weight(0.2)::Slider
          aStrain = Keyword.strain(0)::Slider
          aReach = Keyword.reach(0.05)::Slider
        })::Boolean
      JIL

      faces = BuddyAlert.open_for(owner, "busy").faces
      expect(faces).to include("tiko" => "nerd", "byte" => "nerd", "moss" => "sleeping")
    end

    it "holds nothing for a mood with no axes, or a board alert with no words" do
      run(<<~JIL)
        a = Buddy.mood("busy", {
          aGroups = Keyword.groups("Whisper")::String
          aReach = Keyword.reach(0.1)::Slider
        })::Boolean
        b = Buddy.boardAlert("gate", "", {
          bWarmth = Keyword.warmth(0.4)::Slider
        })::Boolean
      JIL

      expect(BuddyAlert.where(user: owner, key: %w[busy gate])).to be_empty
    end

    it "lets an alert carry a mood in place of a face" do
      run(<<~JIL)
        a = Buddy.boardAlert("gate", "Gate open", {
          aGroups = Keyword.groups("Whisper")::String
          aFace = Keyword.face("pounce")::String
          aWarmth = Keyword.warmth(0.55)::Slider
          aPlay = Keyword.play(0.05)::Slider
          aWeight = Keyword.weight(0.2)::Slider
          aStrain = Keyword.strain(0)::Slider
          aReach = Keyword.reach(0.05)::Slider
        })::Boolean
      JIL

      expect(BuddyAlert.open_for(owner, "gate").face_for(:byte)).to eq("sleeping")
    end
  end
end
