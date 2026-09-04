require "rails_helper"

# The third answer. Not doing it, not refusing — saying what you can't do and
# offering to write it down.
#
# The failure this replaces isn't a refusal, it's the opposite. Told to run a
# 30-minute rhythm with 10-minute breaks, Suki said the breaks were "lined up to
# pop in every half hour until 6:30 PM" and set one countdown (prod 4136).
# Nothing was lined up. The words sounded like help, which is exactly why that
# is the easier mistake to make than saying no.
RSpec.describe "request_feature" do
  let(:owner) { User.me }
  let(:eve)   { create(:user) }
  let!(:eve_convo) {
    eve.byte_conversations.create!(mode: :buddy, name: "Suki", last_message_at: Time.current)
  }
  let!(:owner_convo) {
    owner.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  let(:tool) { Buddy::Tools[:request_feature] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(WebPushNotifications).to receive(:update_count)
  end

  def ask!(user, convo, title, body)
    ctx = Buddy::ToolContext.new(user, conversation: convo)
    tool[:confirm].call({ title: title, body: body }, ctx)
    tool[:execute].call({ title: title, body: body }, ctx)
  end

  describe "writing one down" do
    it "keeps it, against the person who asked" do
      expect {
        ask!(eve, eve_convo, "Work/break rhythm", "30 minutes on, 10 off, until 6:30")
      }.to change { FeatureRequest.count }.by(1)

      row = FeatureRequest.last
      expect(row.user).to eq(eve)
      expect(row.byte_conversation).to eq(eve_convo)
      expect(row.title).to eq("Work/break rhythm")
      expect(row).to be_status_open
    end

    it "refuses one with nothing in it" do
      ctx = Buddy::ToolContext.new(eve, conversation: eve_convo)

      expect { tool[:confirm].call({ title: "", body: "x" }, ctx) }.to raise_error(/no feature/)
      expect { tool[:confirm].call({ title: "x", body: " " }, ctx) }.to raise_error(/no feature/)
    end

    # Level 1. A checkbox in front of "want me to put that on the list?" turns
    # a warm offer into paperwork, and writing something down hurts nobody.
    it "runs without a checkbox and reads itself back" do
      expect(tool[:auto]).to be(true)

      result = ask!(eve, eve_convo, "Repeating timer", "keep restarting it for me")
      expect(tool[:receipt].call(result, nil)).to include("On the list", "Repeating timer")
    end

    it "can be taken back off" do
      result = ask!(eve, eve_convo, "Repeating timer", "keep restarting it for me")

      expect(result[:revert]).to include(op: "created", model: "FeatureRequest")
    end
  end

  # The person who hits the wall is usually not the person who can close it.
  describe "reaching the one person who can do something" do
    it "tells the owner, in their own thread" do
      expect {
        ask!(eve, eve_convo, "Work/break rhythm", "30 on, 10 off until 6:30")
      }.to change { owner_convo.byte_messages.count }.by(1)

      said = owner_convo.byte_messages.last
      expect(said.body).to include(eve.first_name).and include("Work/break rhythm")
      expect(said.metadata["feature_request_id"]).to eq(FeatureRequest.last.id)
    end

    it "pushes, since it's the only time it'll be mentioned" do
      ask!(eve, eve_convo, "Work/break rhythm", "30 on, 10 off")

      expect(WebPushNotifications).to have_received(:send_to_byte)
    end

    it "doesn't tell the owner about their own" do
      expect {
        ask!(owner, owner_convo, "Repeating timer", "keep restarting it")
      }.not_to(change { owner_convo.byte_messages.count })
    end

    # The row is the point. A delivery that blows up must not take it with it.
    it "still keeps the request when the telling fails" do
      allow(Buddy::CompanionDelivery).to receive(:deliver_plain).and_raise("nope")
      allow(Buddy::Errors).to receive(:report)

      expect {
        ask!(eve, eve_convo, "Work/break rhythm", "30 on, 10 off")
      }.to change { FeatureRequest.count }.by(1)
    end
  end

  # Somebody who keeps hitting the same wall says so more than once, and a list
  # with the same gap on it four times is a list nobody reads.
  describe "asking twice" do
    it "adds to the one that's already there" do
      ask!(eve, eve_convo, "Work/break rhythm", "30 minutes on, 10 minutes off")

      expect {
        ask!(eve, eve_convo, "Work break rhythm", "30 minutes working, 10 minutes resting")
      }.not_to(change { FeatureRequest.count })

      expect(FeatureRequest.last.body).to include("resting")
    end

    it "says so, because 'you've asked for that before' is a real answer" do
      ask!(eve, eve_convo, "Work/break rhythm", "30 minutes on, 10 minutes off")
      result = ask!(eve, eve_convo, "Work break rhythm", "30 minutes working, 10 minutes resting")

      expect(tool[:receipt].call(result, nil)).to include("already on the list")
    end

    # Prod 5420-5422. Told "That's not what's needed at all", Byte said "I've
    # put the conditional Whisper Quiet request on the list now" and re-sent the
    # identical body. The merge had nothing to add, `update!` wrote no columns,
    # and request 6's `updated_at` never moved off its `created_at` two minutes
    # earlier. The correction went nowhere and the receipt said it had landed.
    describe "sending the very same words again" do
      it "writes nothing, and says nothing was written" do
        ask!(eve, eve_convo, "Home check before Quiet", "If I'm not home by 12:50, set Quiet for an hour.")
        before = FeatureRequest.last.updated_at

        result = ask!(eve, eve_convo, "Home check before Quiet", "If I'm not home by 12:50, set Quiet for an hour.")

        expect(FeatureRequest.last.updated_at).to eq(before)
        expect(result[:added]).to be(false)
        expect(tool[:receipt].call(result, nil)).to include("word for word")
        expect(tool[:receipt].call(result, nil)).not_to include("Added that")
      end

      # The sentence is written from the tool result, before the receipt is
      # read, so the result is where this has to say so.
      it "tells the model to read back what's there rather than report a filing" do
        ask!(eve, eve_convo, "Home check before Quiet", "If I'm not home by 12:50, set Quiet for an hour.")
        result = ask!(eve, eve_convo, "Home check before Quiet", "If I'm not home by 12:50, set Quiet for an hour.")

        expect(result[:note]).to include("NOTHING WAS WRITTEN")
      end
    end

    # One shared word is how unrelated asks collapse into each other — the
    # lesson from cancelled_like, which matched on one and told somebody they'd
    # switched off a reminder they never had.
    it "keeps two different asks apart when they share a word" do
      ask!(eve, eve_convo, "Repeating timer", "a timer that restarts itself")

      expect {
        ask!(eve, eve_convo, "Timer on the lock screen", "show the countdown without opening the app")
      }.to change { FeatureRequest.count }.by(1)
    end

    it "treats a second ask after it shipped as a new one" do
      ask!(eve, eve_convo, "Work/break rhythm", "30 minutes on, 10 minutes off")
      FeatureRequest.last.update!(status: :shipped)

      expect {
        ask!(eve, eve_convo, "Work/break rhythm", "30 minutes on, 10 minutes off")
      }.to change { FeatureRequest.count }.by(1)
    end
  end

  describe "reading the list back" do
    before do
      ask!(eve, eve_convo, "Work/break rhythm", "30 on, 10 off")
      ask!(owner, owner_convo, "Repeating timer", "keep restarting it")
    end

    it "shows the owner the whole house's" do
      titles = Buddy::FeatureRequests.context_for(owner).map { |r| r[:title] }

      expect(titles).to contain_exactly("Work/break rhythm", "Repeating timer")
    end

    it "shows everybody else only their own" do
      rows = Buddy::FeatureRequests.context_for(eve)

      expect(rows.map { |r| r[:title] }).to eq(["Work/break rhythm"])
      expect(rows.first[:who]).to eq(eve.first_name)
    end

    it "drops the ones that are settled" do
      FeatureRequest.find_by(title: "Repeating timer").update!(status: :declined)

      expect(Buddy::FeatureRequests.context_for(owner).map { |r| r[:title] }).to eq(["Work/break rhythm"])
    end

    it "reaches the model as a context section" do
      built = Buddy::Context.build(owner, owner_convo)

      expect(built[:feature_requests].map { |r| r[:title] }).to include("Repeating timer")
    end
  end

  describe "what the companion is told" do
    it "is offered to everyone, since anybody can hit a wall" do
      expect(Buddy::Features.allows_tool?(eve, tool)).to be(true)
      # CORE, so it can't be withheld — a person without chores or the calendar
      # can still hit a wall, and is arguably likelier to.
      expect(tool[:feature]).to eq(Buddy::Features::CORE)
    end

    it "names the failure it exists to replace" do
      schema = Buddy::Tools.function_schema(tool)

      expect(schema[:description]).to include("lined up to pop in every half hour")
      expect(schema[:description]).to include("your tool list is the authority")
    end

    it "tells the companion to offer it rather than just refusing" do
      prompt = Buddy::Personality.for(eve, conversation: eve_convo)

      expect(prompt).to include("request_feature")
      expect(prompt).to include("narrating an arrangement rather than making the calls")
    end

    # Dev 4079-4083. Asked to check a printer every 30 minutes until the print
    # finished, Byte could do the repeat and not the ending — and then offered
    # "keep that feature request parked, or should I set up the check-ins the
    # plain way?", which is a choice between two things they could have had
    # both of, after they'd already said yes.
    it "says to do the doable half rather than offering a choice" do
      prompt = Buddy::Personality.for(eve, conversation: eve_convo)

      expect(prompt).to include("Do the half you can, and don't make them choose")
    end

    # The same reply then described the repeating check-in as the thing on the
    # list. The row was right; the sentence about it wasn't.
    it "says the request is the part that couldn't be done" do
      schema = Buddy::Tools.function_schema(tool)

      expect(schema[:description]).to include("WRITE DOWN THE PART THAT DOESN'T WORK, not the whole request")
      expect(schema[:description]).to include("DO THE HALF YOU CAN")
      expect(Buddy::Personality.for(eve, conversation: eve_convo)).to include("Say what actually went on the list")
    end
  end
end
