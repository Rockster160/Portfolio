require "rails_helper"

RSpec.describe "Buddy thread replies" do
  # Replying to ONE message instead of to the thread. Which of two completely
  # different things that is depends entirely on what was long-pressed: a
  # relayed message answers the PERSON who sent it, and everything else is an
  # ordinary turn that names what it's about.
  let(:rocco)   { create(:user) }
  let(:chelsea) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: rocco) }
  let!(:convo) { ByteConversation.create!(user: rocco, mode: :buddy, name: "Buddy") }

  # The suite runs Sidekiq inline, so a dispatched turn would make a real call.
  around { |example| Sidekiq::Testing.fake! { example.run } }

  before do
    ChoreHouseholdMembership.create!(chore_household: household, user: chelsea, role: :member)
    rocco.update!(chore_household_id: household.id)
    chelsea.update!(chore_household_id: household.id)

    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(ByteConversation).to receive(:default_theme_for) { |u| u == chelsea ? "moss" : "byte" }
    BuddyDeliverWorker.clear
  end

  # What Chelsea sent, as it sits in Rocco's thread.
  def relayed(kind: :notify, body: "dinner at 6?", options: [])
    relay = BuddyRelay.create!(
      from_user:         chelsea,
      to_user:           rocco,
      from_conversation: Buddy::CompanionRelay.conversation_for(chelsea),
      kind:              kind,
      body:              body,
      options:           options,
      status:            :pending,
    )
    Buddy::CompanionRelay.deliver!(relay)
    [relay.reload, convo.byte_messages.where("metadata->>'source' = 'relay'").order(:created_at).last]
  end

  def reply!(body, to:, user: rocco, conversation: convo)
    ByteMessageIntake.call(user: user, conversation: conversation, body: body, reply_to: to&.id)
  end

  describe "replying to something relayed from the other person" do
    it "sends it back to them, verbatim, without going near Buddy" do
      _relay, incoming = relayed

      reply!("make it 6:30", to: incoming)

      back = BuddyRelay.where(from_user: rocco, to_user: chelsea).last
      expect(back).to have_attributes(kind: "notify", status: "delivered", body: "make it 6:30")
      expect(BuddyDeliverWorker.jobs).to be_empty

      landed = back.to_conversation.byte_messages.order(:created_at).last
      expect(landed.body).to eq("make it 6:30")
      expect(landed.metadata.dig("relay_peer", "name")).to eq("Byte")
    end

    it "leaves their own words on screen ONCE, wearing where they went" do
      _relay, incoming = relayed

      message = reply!("make it 6:30", to: incoming)

      # The typed row IS the outgoing record - a second bubble here would be
      # their own reply printed twice, one of them as though it were incoming.
      expect(convo.byte_messages.where(body: "make it 6:30").count).to eq(1)
      expect(message.reload).to have_attributes(direction: "outbound", state: "sent")
      expect(message.metadata.dig("relay_peer", "name")).to eq("Moss")
      expect(message.metadata["relay_id"]).to eq(BuddyRelay.last.id)
    end

    it "needs the relay row itself to ANSWER, and passes a note along without it" do
      relay, incoming = relayed(kind: :ask_open, body: "what do you want for dinner?")
      incoming.update!(metadata: incoming.metadata.except("relay_id"))

      reply!("tacos", to: incoming)

      # The twin names the person, never the question. Their words still reach
      # her; what is lost is the relay closing, which is the honest trade.
      expect(relay.reload.status).to eq("delivered")
      expect(BuddyRelay.where(from_user: rocco, to_user: chelsea).last.body).to eq("tacos")
    end

    it "ANSWERS an open question rather than starting a new thread of its own" do
      relay, incoming = relayed(kind: :ask_open, body: "what do you want for dinner?")

      reply!("tacos", to: incoming)

      expect(relay.reload).to have_attributes(status: "relayed", answer: "tacos")
      # One relay each way, not a second question left hanging open.
      expect(BuddyRelay.where(from_user: rocco, to_user: chelsea)).to be_empty
      expect(BuddyRelay.open_questions_for(rocco)).to be_empty
    end

    it "answers a question they were asked hours after they were asked it" do
      relay, incoming = relayed(kind: :ask_open, body: "are we leaving at 5:30?")
      # Plenty said since, none of it an answer. An explicit reply reaches past
      # all of it - `passed_over_cutoff` is about a bare "tacos" landing on the
      # wrong question, and pointing at one is not that.
      3.times { |i| convo.byte_messages.create!(user: rocco, direction: :outbound, state: :sent, body: "hm #{i}") }

      reply!("yeah, 5:30 works", to: incoming)

      expect(relay.reload).to have_attributes(status: "relayed", answer: "yeah, 5:30 works")
    end

    it "goes out even while the provider is down, because it never needed it" do
      _relay, incoming = relayed
      Buddy::Outage.down!(detail: "429 insufficient_quota")

      message = reply!("on my way", to: incoming)

      expect(message.reload.state).to eq("sent")
      expect(BuddyRelay.where(from_user: rocco, to_user: chelsea).last.body).to eq("on my way")
    ensure
      Buddy::Outage.clear!
    end

    it "beats the timer parser to the same words" do
      _relay, incoming = relayed(body: "how long on the pasta?")

      expect(Buddy::Timers).not_to receive(:quick_set!)
      reply!("10m", to: incoming)

      expect(BuddyRelay.where(from_user: rocco, to_user: chelsea).last.body).to eq("10m")
    end

    it "sends another note when they reply to one they sent themselves" do
      Buddy::CompanionRelay.pass_along!(from: rocco, to: chelsea, text: "running late", from_conversation: convo)
      copy = convo.byte_messages.where("metadata->>'source' = 'relay_copy'").order(:created_at).last

      reply!("about 20 minutes", to: copy)

      expect(BuddyRelay.where(from_user: rocco, to_user: chelsea).last.body).to eq("about 20 minutes")
    end

    # Prod 4376: "I love you the most!" typed straight at a note from Chelsea.
    # The menu offered "Reply to Moss" off the peer identity on the bubble, the
    # server read `relay_id` and found nothing, and Byte answered it instead.
    # Every one of the 69 bridged messages in prod that day had a twin and not
    # one had a relay_id.
    it "still reaches them when the bridged row predates relay_id" do
      _relay, incoming = relayed
      incoming.update!(metadata: incoming.metadata.except("relay_id"))

      reply!("I love you the most!", to: incoming)

      expect(BuddyRelay.where(from_user: rocco, to_user: chelsea).last.body).to eq("I love you the most!")
      expect(BuddyDeliverWorker.jobs).to be_empty
    end

    it "reads the peer off the twin's owner rather than inferring it" do
      _relay, incoming = relayed
      incoming.update!(metadata: incoming.metadata.except("relay_id"))

      expect(Buddy::ThreadReply.route_for(rocco, incoming)).to include(peer: chelsea, relay: nil)
    end

    it "routes nowhere when the bridge left no partner at all" do
      _relay, incoming = relayed
      incoming.update!(metadata: incoming.metadata.except("relay_id", "relay_twin"))

      reply!("make it 6:30", to: incoming)

      # One of the pre-bridge singletons. It names nobody, so it is an ordinary
      # turn - and the menu won't have offered "Reply to Moss" over it either.
      expect(BuddyRelay.where(from_user: rocco, to_user: chelsea)).to be_empty
      expect(BuddyDeliverWorker.jobs.size).to eq(1)
    end
  end

  describe "replying to anything else" do
    let(:said) {
      convo.byte_messages.create!(
        user:      rocco,
        direction: :inbound,
        state:     :delivered,
        body:      "Which calendar - Ours or Work?",
        metadata:  { "kind" => "buddy" },
      )
    }

    it "runs an ordinary turn carrying the quote" do
      message = reply!("the second one", to: said)

      expect(BuddyDeliverWorker.jobs.size).to eq(1)
      expect(message.metadata["reply_to"]).to include(
        "id" => said.id, "role" => "buddy", "author" => convo.buddy_name,
        "excerpt" => "Which calendar - Ours or Work?"
      )
    end

    it "quotes their own earlier message as theirs" do
      mine = convo.byte_messages.create!(user: rocco, direction: :outbound, state: :sent, body: "grab batteries")

      message = reply!("AA not AAA", to: mine)

      expect(message.metadata["reply_to"]).to include("role" => "self", "author" => "You")
    end

    it "reads a picture with no caption as a picture" do
      photo = convo.byte_messages.create!(user: rocco, direction: :inbound, state: :delivered, body: "")
      photo.files.attach(io: StringIO.new("x"), filename: "shot.png", content_type: "image/png")

      message = reply!("what's that?", to: photo.reload)

      expect(message.metadata.dig("reply_to", "excerpt")).to eq("a picture")
    end

    it "ignores a message from a thread they aren't in" do
      other = ByteConversation.create!(user: chelsea, mode: :buddy, name: "Hers")
      theirs = other.byte_messages.create!(user: chelsea, direction: :outbound, state: :sent, body: "private")

      message = reply!("hm", to: theirs)

      expect(message.metadata).not_to have_key("reply_to")
    end
  end

  describe "Buddy::ThreadReply.quote" do
    it "names the other household's companion on something they relayed in" do
      _relay, incoming = relayed

      expect(Buddy::ThreadReply.quote(incoming)).to include("author" => "Moss", "role" => "relay_in")
    end

    it "credits the person for the copy of what they sent out" do
      Buddy::CompanionRelay.pass_along!(from: rocco, to: chelsea, text: "running late", from_conversation: convo)
      copy = convo.byte_messages.where("metadata->>'source' = 'relay_copy'").order(:created_at).last

      expect(Buddy::ThreadReply.quote(copy)).to include("author" => "You", "role" => "relay_out")
    end

    it "clips a long message rather than carrying the whole thing forever" do
      long = convo.byte_messages.create!(user: rocco, direction: :outbound, state: :sent, body: "x" * 400)

      expect(Buddy::ThreadReply.quote(long)["excerpt"].length).to eq(Buddy::ThreadReply::EXCERPT_LIMIT)
    end
  end
end
