require "rails_helper"

# The third answer. Not doing it, not refusing — saying what you can't do and
# writing it down as a FeatureRequest.
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
    it "keeps it against the person who asked, revertably", :aggregate_failures do
      result = nil
      expect {
        result = ask!(eve, eve_convo, "Work/break rhythm", "30 minutes on, 10 off, until 6:30")
      }.to change { FeatureRequest.count }.by(1)

      row = FeatureRequest.last
      expect(row.user).to eq(eve)
      expect(row.byte_conversation).to eq(eve_convo)
      expect(row.title).to eq("Work/break rhythm")
      expect(row).to be_status_open
      expect(result[:revert]).to include(op: "created", model: "FeatureRequest")
    end

    it "refuses one with nothing in it" do
      ctx = Buddy::ToolContext.new(eve, conversation: eve_convo)

      expect { tool[:confirm].call({ title: "", body: "x" }, ctx) }.to raise_error(/no feature/)
      expect { tool[:confirm].call({ title: "x", body: " " }, ctx) }.to raise_error(/no feature/)
    end
  end

  # The person who hits the wall is usually not the person who can close it.
  describe "reaching the one person who can do something" do
    it "tells the owner, in their own thread, with a push", :aggregate_failures do
      expect {
        ask!(eve, eve_convo, "Work/break rhythm", "30 on, 10 off until 6:30")
      }.to change { owner_convo.byte_messages.count }.by(1)

      said = owner_convo.byte_messages.last
      expect(said.body).to include(eve.first_name).and include("Work/break rhythm")
      expect(said.metadata["feature_request_id"]).to eq(FeatureRequest.last.id)
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
    # The title is what anybody reading the list sees, so it keeps naming the
    # gap it was written for.
    it "adds to the one that's already there, keeping its title", :aggregate_failures do
      ask!(eve, eve_convo, "Work/break rhythm", "30 minutes on, 10 minutes off")

      result = nil
      expect {
        result = ask!(eve, eve_convo, "Work break rhythm", "30 minutes working, 10 minutes resting")
      }.not_to(change { FeatureRequest.count })

      expect(FeatureRequest.last.body).to include("resting")
      expect(result[:title]).to eq("Work/break rhythm")
    end

    # Identical words have nothing to merge, and the result must not read as a
    # filing that landed.
    it "writes nothing for the very same words again, and says so in the result", :aggregate_failures do
      ask!(eve, eve_convo, "Home check before Quiet", "If I'm not home by 12:50, set Quiet for an hour.")
      before = FeatureRequest.last.updated_at

      result = ask!(eve, eve_convo, "Home check before Quiet", "If I'm not home by 12:50, set Quiet for an hour.")

      expect(FeatureRequest.last.updated_at).to eq(before)
      expect(result[:added]).to be(false)
      expect(result[:note]).to be_present
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

    # Incidental shared words in long bodies must not merge unrelated asks.
    it "keeps a request about an event's notes off a row about running timers" do
      timer = "User wants to attach a follow-on action to the end of a timer while it is " \
              "already running, so the next step happens automatically when the timer completes."
      link  = "They want a reminder 45 minutes before interview events that includes a link to " \
              "the company. I can anchor the reminder but can't attach the link automatically."

      ask!(eve, eve_convo, "Chain actions onto running timers", timer)
      ask!(eve, eve_convo, "Reminder link from event notes", link)

      expect(FeatureRequest.live.pluck(:title)).to contain_exactly(
        "Chain actions onto running timers", "Reminder link from event notes"
      )
    end

    # A merge APPENDS, so judging on the body would make each merge raise the
    # odds of the next.
    it "doesn't get more absorbent each time something is merged into it" do
      ask!(eve, eve_convo, "Work/break rhythm", "30 minutes on, 10 minutes off")
      ask!(eve, eve_convo, "Work break rhythm", "attach a break automatically after each stretch")

      ask!(eve, eve_convo, "Pantry photo search", "find a thing in the pantry from a picture")

      expect(FeatureRequest.live.pluck(:title)).to include("Pantry photo search")
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

    it "shows the owner the whole house's and everybody else only their own", :aggregate_failures do
      titles = Buddy::FeatureRequests.context_for(owner).map { |r| r[:title] }
      rows = Buddy::FeatureRequests.context_for(eve)

      expect(titles).to contain_exactly("Work/break rhythm", "Repeating timer")
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

  # CORE, so it can't be withheld from someone without chores or the calendar.
  it "is offered to everyone, since anybody can hit a wall" do
    expect(Buddy::Features.allows_tool?(eve, tool)).to be(true)
  end
end
