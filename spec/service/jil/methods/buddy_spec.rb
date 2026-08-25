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
end
