require "rails_helper"

# A tapback on a relayed message. The thing that makes it more than a flag on a
# row is that a relayed message exists TWICE — the recipient's copy and the
# sender's record — and one person's 👍 has to show up on both of them.
RSpec.describe Buddy::Reactions do
  let(:sender)    { create(:user) }
  let(:recipient) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: sender) }
  let!(:sender_convo) {
    sender.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let!(:recipient_convo) {
    recipient.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: Time.current)
  }
  let(:broadcasts) { [] }
  let(:pushes)     { [] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to) { |user, payload| broadcasts << [user, payload] }
    allow(WebPushNotifications).to receive(:send_to_byte) { |args| pushes << args }
    allow(::WebPushNotifications).to receive(:update_count)
    ChoreHouseholdMembership.create!(chore_household: household, user: recipient, role: :member)
    sender.update!(chore_household_id: household.id)
    recipient.update!(chore_household_id: household.id)
  end

  # One relay, delivered. Returns [their copy, my record].
  def relayed
    Buddy::CompanionRelay.pass_along!(
      from: sender, to: recipient, text: "dinner's ready", from_conversation: sender_convo,
    )
    [
      recipient_convo.byte_messages.order(:id).last,
      sender_convo.byte_messages.order(:id).last,
    ]
  end

  # A pick-one question: a bridged message on both sides, with answer buttons
  # attached to the recipient's copy from inside bridge!.
  def asked_choice
    relay = BuddyRelay.create!(
      from_user: sender, to_user: recipient, from_conversation: sender_convo,
      kind: :ask_choice, body: "watch something while we eat?",
      options: %w[yes no], status: :pending
    )
    Buddy::CompanionRelay.deliver!(relay)
    relay
  end

  describe "linking the two copies" do
    it "points each copy of a relay, and of the answer that comes back, at the other", :aggregate_failures do
      theirs, mine = relayed
      expect(theirs.reload.metadata["relay_twin"]).to eq(mine.id)
      expect(mine.metadata["relay_twin"]).to eq(theirs.id)

      relay = BuddyRelay.create!(
        from_user: sender, to_user: recipient, from_conversation: sender_convo,
        kind: :ask_open, body: "are you eating with us?", status: :pending
      )
      Buddy::CompanionRelay.deliver!(relay)
      Buddy::CompanionRelay.record_answer!(relay.reload, "yes")

      answer = sender_convo.byte_messages.where(body: "yes").last
      expect(answer.metadata["relay_twin"]).to be_present
      expect(described_class.twin_of(answer).body).to eq("yes")
    end

    # The choice-question path runs a block inside bridge! that does its own
    # metadata `update!` to attach the answer buttons, so the twin stamp has to
    # merge with it rather than be written before it or off a stale object.
    it "links a choice question with its buttons intact, and carries reactions across both ways", :aggregate_failures do
      relay = asked_choice
      question = recipient_convo.byte_messages.order(:id).last
      copy     = sender_convo.byte_messages.order(:id).last

      expect(question.metadata["relay_twin"]).to eq(copy.id)
      expect(copy.metadata["relay_twin"]).to eq(question.id)
      expect(question.metadata["tool_name"]).to eq("buddy_relay_answer")
      expect(question.metadata["buttons"].length).to eq(2)
      expect(relay.reload.to_byte_action).to be_present

      pushes.clear
      described_class.react!(message: question, user: recipient, emoji: "👍")
      expect(described_class.of(copy.reload).pluck("emoji")).to eq(["👍"])
      expect(described_class.of(copy).first["user_id"]).to eq(recipient.id)
      expect(pushes.first[:users]).to eq([sender])

      Buddy::CompanionRelay.record_answer!(relay.reload, "yes")
      answer = sender_convo.byte_messages.where(body: "yes").last
      answer_copy = described_class.twin_of(answer)
      pushes.clear
      described_class.react!(message: answer, user: sender, emoji: "❤️")
      expect(described_class.of(answer_copy.reload).pluck("emoji")).to eq(["❤️"])
      expect(pushes.first[:users]).to eq([recipient])
    end
  end

  # One per person, on both copies: a different emoji is a change of mind, and
  # one person removing theirs leaves the other's.
  it "toggles one reaction per person, on both copies, in the order they were left", :aggregate_failures do
    theirs, mine = relayed
    both = -> { [theirs.reload, mine.reload].map { |m| described_class.of(m).pluck("emoji") } }

    described_class.react!(message: theirs, user: recipient, emoji: "👍")
    expect(both.call).to eq([["👍"], ["👍"]])
    expect(described_class.of(mine).first).to include("user_id" => recipient.id, "name" => recipient.first_name)

    described_class.react!(message: theirs.reload, user: recipient, emoji: "❤️")
    expect(both.call).to eq([["❤️"], ["❤️"]])

    described_class.react!(message: mine.reload, user: sender, emoji: "😂")
    expect(both.call).to eq([["❤️", "😂"], ["❤️", "😂"]])

    described_class.react!(message: theirs.reload, user: recipient, emoji: "❤️")
    expect(both.call).to eq([["😂"], ["😂"]])
    expect(described_class.of(mine).pluck("user_id")).to eq([sender.id])
  end

  describe "reaching the other person" do
    # A reaction is not a message arriving, so the broadcast is marked an update
    # or the client counts it as new. Both sides get one shape, carrying who
    # and what, since with the app open the OS banner is suppressed.
    # `byte_worker.js` reads a missing count as zero and CLEARS the badge.
    it "broadcasts the same update to both and pushes the other person with the unread total", :aggregate_failures do
      theirs, = relayed
      broadcasts.clear
      pushes.clear
      before = ByteConversation.unread_total_for(sender)

      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      expect(broadcasts.map(&:first)).to contain_exactly(recipient, sender)
      expect(broadcasts.map { |_, payload| payload[:data][:update] }).to all(be(true))
      expect(broadcasts.map { |_, payload| payload[:data][:reaction] }).to all(
        eq(by: recipient.id, name: recipient.first_name, value: "👍", added: true),
      )

      expect(pushes.length).to eq(1)
      expect(pushes.first[:users]).to eq([sender])
      expect(pushes.first[:title]).to include("👍", recipient.first_name, "dinner's ready")
      expect(pushes.first[:data][:count]).to eq(before)
      expect(ByteConversation.unread_total_for(sender.reload)).to eq(before)
    end

    # Taking a reaction back is not news.
    it "marks a removal as such and pushes nothing for it", :aggregate_failures do
      theirs, = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "👍")
      broadcasts.clear
      pushes.clear

      described_class.react!(message: theirs.reload, user: recipient, emoji: "👍")

      expect(broadcasts.map { |_, p| p[:data][:reaction][:added] }).to all(be(false))
      expect(pushes).to be_empty
    end
  end

  # A reaction is an icon REFERENCE: an emoji, a `ti-*` class, or one of the
  # household's own uploads. `hicon:` only resolves inside the household that
  # owns it, which is also the authorization check.
  describe "what you can react with" do
    let!(:custom) {
      HouseholdIcon.create!(
        chore_household: household, uploaded_by_user: sender, name: "Fae",
        image_data: "data:image/png;base64,iVBORw0KGgo="
      )
    }

    it "takes a Tabler icon or a household upload, naming each in the push", :aggregate_failures do
      theirs, mine = relayed

      described_class.react!(message: theirs, user: recipient, emoji: "ti-fa-fire")
      expect(described_class.of(mine.reload).pluck("emoji")).to eq(["ti-fa-fire"])

      pushes.clear
      described_class.react!(message: theirs.reload, user: recipient, emoji: "hicon:#{custom.id}")
      expect(described_class.of(mine.reload).pluck("emoji")).to eq(["hicon:#{custom.id}"])
      expect(pushes.first[:title]).to include('"Fae"')

      # A push can't show an image, and "ti-fa-fire" means nothing to anybody.
      expect(described_class.label_for("👍", user: recipient)).to eq("👍")
      expect(described_class.label_for("hicon:#{custom.id}", user: recipient)).to eq('"Fae"')
      expect(described_class.label_for("ti-fa-fire", user: recipient)).to start_with('"')
    end

    it "refuses another household's upload, a made-up one, a blank, or text not in the pool", :aggregate_failures do
      outsider = create(:user)
      foreign = HouseholdIcon.create!(
        chore_household: ChoreHousehold.create!(name: "Elsewhere", owner_user: outsider),
        uploaded_by_user: outsider, name: "Nope", image_data: "data:image/png;base64,iVBORw0KGgo="
      )

      expect(described_class.allowed?("hicon:#{foreign.id}", user: recipient)).to be(false)
      expect(described_class.allowed?("hicon:999999", user: recipient)).to be(false)
      expect(described_class.allowed?("", user: recipient)).to be(false)

      theirs, = relayed
      expect { described_class.react!(message: theirs, user: recipient, emoji: "lol nice one") }.to raise_error(ArgumentError)
    end
  end

  # Most-recently-used, so the row becomes the six they keep reaching for.
  # Reaching for one again moves it to the front instead of repeating it, and
  # taking one back off isn't reaching for it.
  it "keeps six recents, most recent first, padded with defaults", :aggregate_failures do
    expect(described_class.recents_for(recipient)).to eq(described_class::DEFAULTS)

    theirs, mine = relayed
    described_class.react!(message: theirs, user: recipient, emoji: "ti-fa-fire")
    recents = described_class.recents_for(recipient.reload)
    expect(recents.first).to eq("ti-fa-fire")
    expect(recents.length).to eq(6)

    described_class.react!(message: theirs.reload, user: recipient, emoji: "😂")
    described_class.react!(message: mine.reload, user: recipient, emoji: "ti-fa-fire")
    recents = described_class.recents_for(recipient.reload)
    expect(recents.count("ti-fa-fire")).to eq(1)
    expect(recents.first).to eq("ti-fa-fire")

    described_class.react!(message: mine.reload, user: recipient, emoji: "ti-fa-fire")
    expect(described_class.recents_for(recipient.reload).first).to eq("ti-fa-fire")

    %w[ti-fa-heart ti-fa-star ti-fa-bell ti-fa-home ti-fa-cloud ti-fa-flag].each do |icon|
      described_class.react!(message: theirs.reload, user: recipient, emoji: icon)
    end
    expect(recipient.reload.byte_reaction_recents.length).to eq(6)
    expect(recipient.byte_reaction_recents).not_to include("ti-fa-fire")
  end

  # Anything in the thread takes one, not just what passed between two people.
  describe "what can be reacted to" do
    def message_of(kind, body: "all set", direction: :inbound)
      recipient_convo.byte_messages.create!(
        user: recipient, direction: direction, state: :delivered, body: body,
        metadata: { "kind" => kind }, delivered_at: Time.current
      )
    end

    it "takes one on any kind of message, including their own", :aggregate_failures do
      messages = %w[buddy_reply buddy buddy_receipt buddy_activity action_chip claude system watch].map { |kind| message_of(kind) }
      messages << message_of(nil, body: "on my way", direction: :outbound)

      messages.each do |message|
        described_class.react!(message: message, user: recipient, emoji: "👍")

        expect(described_class.of(message.reload).pluck("emoji")).to eq(["👍"]), message.metadata["kind"].inspect
      end
    end

    # Reacting to Buddy is a note to yourself. It must not look like input, and
    # an old message reacted to must not jump its thread to the top of the
    # drawer.
    it "says nothing back, runs no turn, pushes nobody, and leaves the thread's activity alone", :aggregate_failures do
      message = message_of("buddy_reply")
      recipient_convo.update!(last_message_at: 3.days.from_now)
      was = recipient_convo.reload.last_message_at
      allow(ByteMessageIntake).to receive(:call)
      pushes.clear

      expect { described_class.react!(message: message, user: recipient, emoji: "👍") }.not_to change(ByteMessage, :count)

      expect(ByteMessageIntake).not_to have_received(:call)
      expect(pushes).to be_empty
      expect(recipient_convo.reload.last_message_at).to eq(was)
    end
  end

  # A relay sent before the copies were linked: the reaction still lands on the
  # row in front of the person; it just has nowhere else to go.
  it "records a reaction on an unlinked copy without a twin" do
    theirs, = relayed
    theirs.update!(metadata: theirs.metadata.except("relay_twin"))

    expect { described_class.react!(message: theirs, user: recipient, emoji: "👍") }.not_to raise_error
    expect(described_class.of(theirs.reload).pluck("emoji")).to eq(["👍"])
  end
end
