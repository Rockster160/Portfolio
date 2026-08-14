require "rails_helper"

RSpec.describe Jil::Methods::Buddy do
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
    JIL
    expect { Jil::Validator.validate!(code) }.not_to raise_error
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
