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
    it "points each copy at the other" do
      theirs, mine = relayed

      expect(theirs.reload.metadata["relay_twin"]).to eq(mine.id)
      expect(mine.metadata["relay_twin"]).to eq(theirs.id)
    end

    # The choice-question path is the one that runs a block inside bridge! to
    # attach the answer buttons, and that block does its own metadata `update!`.
    # If the twin stamp were written before it, or read off a stale object, the
    # question card would be the one thing in the thread whose reaction went
    # nowhere — and it's the message most likely to get one.
    it "links a choice question, buttons and all" do
      relay = asked_choice
      question = recipient_convo.byte_messages.order(:id).last
      copy     = sender_convo.byte_messages.order(:id).last

      expect(question.metadata["relay_twin"]).to eq(copy.id)
      expect(copy.metadata["relay_twin"]).to eq(question.id)
      # The buttons survived the stamp — both writes merged rather than replaced.
      expect(question.metadata["tool_name"]).to eq("buddy_relay_answer")
      expect(question.metadata["buttons"].length).to eq(2)
      expect(relay.reload.to_byte_action).to be_present
    end

    # End to end, on the shape the question actually has.
    it "carries a reaction on a choice question across to the asker" do
      asked_choice
      question = recipient_convo.byte_messages.order(:id).last
      copy     = sender_convo.byte_messages.order(:id).last
      pushes.clear

      described_class.react!(message: question, user: recipient, emoji: "👍")

      expect(described_class.of(copy.reload).pluck("emoji")).to eq(["👍"])
      expect(described_class.of(copy).first["user_id"]).to eq(recipient.id)
      expect(pushes.first[:users]).to eq([sender])
    end

    # And the other direction: the asker reacting to the answer that came back.
    it "carries a reaction on the answer across to the answerer" do
      relay = asked_choice
      Buddy::CompanionRelay.record_answer!(relay.reload, "yes")
      answer = sender_convo.byte_messages.where(body: "yes").last
      answer_copy = described_class.twin_of(answer)
      pushes.clear

      described_class.react!(message: answer, user: sender, emoji: "❤️")

      expect(answer_copy).to be_present
      expect(described_class.of(answer_copy.reload).pluck("emoji")).to eq(["❤️"])
      expect(pushes.first[:users]).to eq([recipient])
    end

    it "links the answer that comes back too" do
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
  end

  describe "toggling" do
    it "lands on both copies, not just the one they tapped" do
      theirs, mine = relayed

      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      expect(described_class.of(theirs.reload).pluck("emoji")).to eq(["👍"])
      expect(described_class.of(mine.reload).pluck("emoji")).to eq(["👍"])
      expect(described_class.of(mine).first["user_id"]).to eq(recipient.id)
      expect(described_class.of(mine).first["name"]).to eq(recipient.first_name)
    end

    it "takes it back off both when they tap the same one again" do
      theirs, mine = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      described_class.react!(message: theirs.reload, user: recipient, emoji: "👍")

      expect(described_class.of(theirs.reload)).to be_empty
      expect(described_class.of(mine.reload)).to be_empty
    end

    # One per person: a different emoji is a change of mind, not a second vote.
    it "replaces their reaction rather than stacking a second one" do
      theirs, mine = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      described_class.react!(message: theirs.reload, user: recipient, emoji: "❤️")

      expect(described_class.of(mine.reload).pluck("emoji")).to eq(["❤️"])
    end

    it "keeps both people's, in the order they left them" do
      theirs, mine = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "👍")
      described_class.react!(message: mine.reload, user: sender, emoji: "😂")

      expect(described_class.of(theirs.reload).pluck("emoji")).to eq(["👍", "😂"])
      expect(described_class.of(mine.reload).pluck("emoji")).to eq(["👍", "😂"])
    end

    # One person removing theirs must not take the other's with it.
    it "leaves the other person's alone on a removal" do
      theirs, mine = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "👍")
      described_class.react!(message: mine.reload, user: sender, emoji: "😂")

      described_class.react!(message: theirs.reload, user: recipient, emoji: "👍")

      expect(described_class.of(mine.reload).pluck("user_id")).to eq([sender.id])
    end
  end

  describe "reaching the other person" do
    it "broadcasts to both of them" do
      theirs, = relayed
      broadcasts.clear

      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      expect(broadcasts.map(&:first)).to contain_exactly(recipient, sender)
    end

    it "pushes the other person, and says who and what" do
      theirs, = relayed
      pushes.clear

      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      expect(pushes.length).to eq(1)
      expect(pushes.first[:users]).to eq([sender])
      expect(pushes.first[:title]).to include("👍", recipient.first_name, "dinner's ready")
    end

    # A reaction is not a message arriving. The broadcast has to say so, or the
    # client counts the re-broadcast as new the moment the thread has been read
    # and the live id set cleared — a badge for something nobody said.
    it "marks the broadcast as an update, not an arrival" do
      theirs, = relayed
      broadcasts.clear

      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      expect(broadcasts.map { |_, payload| payload[:data][:update] }).to all(be(true))
    end

    # With the app open the OS banner is suppressed on purpose, and a reaction
    # has nothing else to announce it — so the client raises its own strip. It
    # needs to know who and what without diffing the list against its cache.
    it "says who reacted and with what" do
      theirs, = relayed
      broadcasts.clear

      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      detail = broadcasts.map { |_, payload| payload[:data][:reaction] }
      expect(detail).to all(
        eq(by: recipient.id, name: recipient.first_name, value: "👍", added: true),
      )
    end

    # The reactor gets the same payload and filters themselves out client-side.
    # One shape on the wire beats two that have to be kept in step.
    it "sends the same detail to both sides" do
      theirs, = relayed
      broadcasts.clear

      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      expect(broadcasts.length).to eq(2)
      expect(broadcasts.map { |_, p| p[:data][:reaction] }.uniq.length).to eq(1)
    end

    # A notice for a reaction being taken away would be a notice for nothing.
    it "marks a removal as such so no notice is raised for it" do
      theirs, = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "👍")
      broadcasts.clear

      described_class.react!(message: theirs.reload, user: recipient, emoji: "👍")

      expect(broadcasts.map { |_, p| p[:data][:reaction][:added] }).to all(be(false))
    end

    # `byte_worker.js` reads a missing count as zero and CLEARS the badge, so
    # omitting it would wipe real unread messages off the app icon every time
    # somebody left a 👍. Sending the live total leaves it exactly as it was.
    it "carries the unread total so the badge is left alone" do
      theirs, = relayed
      pushes.clear
      before = ByteConversation.unread_total_for(sender)

      described_class.react!(message: theirs, user: recipient, emoji: "👍")

      expect(pushes.first[:data][:count]).to eq(before)
      expect(ByteConversation.unread_total_for(sender.reload)).to eq(before)
    end

    # Taking a reaction back is not news.
    it "doesn't push on a removal" do
      theirs, = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "👍")
      pushes.clear

      described_class.react!(message: theirs.reload, user: recipient, emoji: "👍")

      expect(pushes).to be_empty
    end
  end

  # A reaction is an icon REFERENCE, the same three shapes the picker hands back
  # everywhere else: an emoji, a `ti-*` class, or one of the household's own
  # uploads. Anything you can put on a chore you can react with.
  describe "what you can react with" do
    let!(:custom) {
      HouseholdIcon.create!(
        chore_household: household, uploaded_by_user: sender, name: "Fae",
        image_data: "data:image/png;base64,iVBORw0KGgo="
      )
    }

    it "takes a Tabler icon" do
      theirs, mine = relayed

      described_class.react!(message: theirs, user: recipient, emoji: "ti-fa-fire")

      expect(described_class.of(mine.reload).pluck("emoji")).to eq(["ti-fa-fire"])
    end

    it "takes one of the household's own uploads" do
      theirs, mine = relayed

      described_class.react!(message: theirs, user: recipient, emoji: "hicon:#{custom.id}")

      expect(described_class.of(mine.reload).pluck("emoji")).to eq(["hicon:#{custom.id}"])
    end

    # `hicon:` only resolves inside the household that owns it, which is also
    # the authorization check — nobody else's uploads are reachable.
    it "refuses an upload from outside the household" do
      outsider = create(:user)
      other_household = ChoreHousehold.create!(name: "Elsewhere", owner_user: outsider)
      foreign = HouseholdIcon.create!(
        chore_household: other_household, uploaded_by_user: outsider, name: "Nope",
        image_data: "data:image/png;base64,iVBORw0KGgo="
      )

      expect(described_class.allowed?("hicon:#{foreign.id}", user: recipient)).to be(false)
    end

    it "refuses a made-up icon reference" do
      expect(described_class.allowed?("hicon:999999", user: recipient)).to be(false)
    end

    # Validated by asking the pool, not by a regex guessing at what an emoji is.
    # The picker only ever offers a pool row, so free text is hand-crafted.
    it "refuses text that isn't in the pool" do
      theirs, = relayed

      expect { described_class.react!(message: theirs, user: recipient, emoji: "lol nice one") }
        .to raise_error(ArgumentError, /isn't something you can react with/)
    end

    it "refuses a blank" do
      expect(described_class.allowed?("", user: recipient)).to be(false)
    end
  end

  # What a push calls a reaction, since it can't show an uploaded image and
  # "ti-fa-fire" means nothing to anybody.
  describe "naming one" do
    it "leaves an emoji as itself" do
      expect(described_class.label_for("👍", user: recipient)).to eq("👍")
    end

    it "names a household upload" do
      icon = HouseholdIcon.create!(
        chore_household: household, uploaded_by_user: sender, name: "Fae",
        image_data: "data:image/png;base64,iVBORw0KGgo="
      )

      expect(described_class.label_for("hicon:#{icon.id}", user: recipient)).to eq('"Fae"')
    end

    it "names a Tabler icon" do
      expect(described_class.label_for("ti-fa-fire", user: recipient)).to start_with('"')
    end

    it "says what it was in the push" do
      icon = HouseholdIcon.create!(
        chore_household: household, uploaded_by_user: sender, name: "Fae",
        image_data: "data:image/png;base64,iVBORw0KGgo="
      )
      theirs, = relayed
      pushes.clear

      described_class.react!(message: theirs, user: recipient, emoji: "hicon:#{icon.id}")

      expect(pushes.first[:title]).to eq(
        "#{recipient.first_name} reacted \"Fae\" to \"dinner's ready\"",
      )
    end
  end

  # The row is most-recently-used, so it becomes the six they keep reaching for
  # rather than the six somebody picked as defaults.
  describe "recents" do
    it "starts as the defaults" do
      expect(described_class.recents_for(recipient)).to eq(described_class::DEFAULTS)
    end

    it "puts what they just used at the front" do
      theirs, = relayed

      described_class.react!(message: theirs, user: recipient, emoji: "ti-fa-fire")

      expect(described_class.recents_for(recipient.reload).first).to eq("ti-fa-fire")
    end

    it "still shows six, padded with defaults" do
      theirs, = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "ti-fa-fire")

      expect(described_class.recents_for(recipient.reload).length).to eq(6)
    end

    # Reaching for the same one again moves it back to the front instead of
    # repeating it — which is what makes the row settle rather than churn.
    it "doesn't repeat one they'd already used" do
      theirs, mine = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "ti-fa-fire")
      described_class.react!(message: theirs.reload, user: recipient, emoji: "😂")
      described_class.react!(message: mine.reload, user: recipient, emoji: "ti-fa-fire")

      recents = described_class.recents_for(recipient.reload)
      expect(recents.count("ti-fa-fire")).to eq(1)
      expect(recents.first).to eq("ti-fa-fire")
    end

    it "keeps only the six most recent of their own" do
      theirs, = relayed
      %w[ti-fa-fire ti-fa-heart ti-fa-star ti-fa-bell ti-fa-home ti-fa-cloud ti-fa-flag].each do |icon|
        described_class.react!(message: theirs.reload, user: recipient, emoji: icon)
      end

      expect(recipient.reload.byte_reaction_recents.length).to eq(6)
      expect(recipient.byte_reaction_recents).not_to include("ti-fa-fire")
    end

    # Taking one back off isn't reaching for it.
    it "doesn't record a removal" do
      theirs, = relayed
      described_class.react!(message: theirs, user: recipient, emoji: "😂")
      described_class.react!(message: theirs.reload, user: recipient, emoji: "ti-fa-fire")
      described_class.react!(message: theirs.reload, user: recipient, emoji: "ti-fa-fire")

      expect(described_class.recents_for(recipient.reload).first).to eq("ti-fa-fire")
    end
  end

  # Anything in the thread takes one, not just what passed between two people.
  describe "what can be reacted to" do
    def message_of(kind, body: "all set", direction: :inbound)
      recipient_convo.byte_messages.create!(
        user: recipient, direction: direction, state: :delivered, body: body,
        metadata: { "kind" => kind }, delivered_at: Time.current
      )
    end

    %w[buddy_reply buddy buddy_receipt buddy_activity action_chip claude system watch].each do |kind|
      it "takes one on a #{kind} message" do
        message = message_of(kind)

        described_class.react!(message: message, user: recipient, emoji: "👍")

        expect(described_class.of(message.reload).pluck("emoji")).to eq(["👍"])
      end
    end

    it "takes one on something they sent themselves" do
      mine = message_of(nil, body: "on my way", direction: :outbound)

      described_class.react!(message: mine, user: recipient, emoji: "👍")

      expect(described_class.of(mine.reload).pluck("emoji")).to eq(["👍"])
    end

    # Reacting to Buddy is a note to yourself. It must not look like input.
    it "doesn't say anything back, or run a turn" do
      message = message_of("buddy_reply")
      allow(ByteMessageIntake).to receive(:call)

      expect { described_class.react!(message: message, user: recipient, emoji: "👍") }
        .not_to change(ByteMessage, :count)
      expect(ByteMessageIntake).not_to have_received(:call)
    end

    it "pushes nobody — there's no other side to a message in your own thread" do
      message = message_of("buddy_reply")
      pushes.clear

      described_class.react!(message: message, user: recipient, emoji: "👍")

      expect(pushes).to be_empty
    end

    # An old message reacted to must not jump its thread to the top of the
    # drawer: nothing was said, and the ordering is by when things were.
    it "doesn't bump the conversation's activity" do
      message = message_of("buddy_reply")
      recipient_convo.update!(last_message_at: 3.days.from_now)
      was = recipient_convo.reload.last_message_at

      described_class.react!(message: message, user: recipient, emoji: "👍")

      expect(recipient_convo.reload.last_message_at).to eq(was)
    end
  end

  # A relay sent before the copies were linked and never backfilled. The
  # reaction still lands on the row in front of the person rather than blowing
  # up; it just has nowhere else to go.
  describe "an unlinked copy" do
    it "records it without a twin" do
      theirs, = relayed
      theirs.update!(metadata: theirs.metadata.except("relay_twin"))

      expect { described_class.react!(message: theirs, user: recipient, emoji: "👍") }
        .not_to raise_error
      expect(described_class.of(theirs.reload).pluck("emoji")).to eq(["👍"])
    end
  end
end
