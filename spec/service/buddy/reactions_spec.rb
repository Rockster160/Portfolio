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

  describe "linking the two copies" do
    it "points each copy at the other" do
      theirs, mine = relayed

      expect(theirs.reload.metadata["relay_twin"]).to eq(mine.id)
      expect(mine.metadata["relay_twin"]).to eq(theirs.id)
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

  describe "what can be reacted to" do
    # Buddy's own replies, receipts and action cards are not conversation with
    # anybody, so there is no one for a tapback to reach.
    it "refuses a message that didn't pass between two people" do
      own = recipient_convo.byte_messages.create!(
        user: recipient, direction: :inbound, state: :delivered,
        body: "all set", metadata: { "kind" => "buddy_reply" }, delivered_at: Time.current
      )

      expect(described_class.reactable?(own)).to be(false)
      expect { described_class.react!(message: own, user: recipient, emoji: "👍") }
        .to raise_error(ArgumentError, /can't be reacted to/)
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
