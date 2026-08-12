require "rails_helper"

# The drawer panel is deliberately read-mostly: steps are tool calls with
# validated arguments, which get written by talking to Byte. What lives here is
# the part conversation is bad at - seeing them all, fixing a name, muting one,
# throwing one away.
RSpec.describe Buddy::RoutinesController, type: :controller do
  let(:user) { User.me }

  before { sign_in user }

  # Every line this pet could have reached for, as one pattern. What a routine
  # says is the companion's own voice (Buddy::VoiceLines) and there are several
  # of each, so a spec pins the SET rather than a phrasing nobody promised.
  def one_of(kind, theme, **vars)
    Regexp.union(
      Buddy::VoiceLines.lines_for(theme, kind).map { |line| Buddy::VoiceLines.render(line[:say], vars) },
    )
  end

  def routine!(name, enabled: true)
    BuddyRoutine.create!(
      user:    user,
      name:    name,
      enabled: enabled,
      steps:   [BuddyRoutine.step(:message_partner, { to: "someone", message: "night" })],
    )
  end

  describe "GET #index" do
    it "lists them alphabetically, with the steps spelled out" do
      routine!("Wind Down")
      routine!("Prep Printer")

      get :index
      body = response.parsed_body

      expect(response).to be_successful
      expect(body["routines"].pluck("name")).to eq(["Prep Printer", "Wind Down"])
      expect(body["routines"].first["summary"]).to be_present
    end

    it "includes the disabled ones, since turning one back on is the point" do
      routine!("Off", enabled: false)

      get :index

      expect(response.parsed_body["routines"].pluck("enabled")).to eq([false])
    end

    it "never shows someone else's" do
      BuddyRoutine.create!(
        user:  create(:user),
        name:  "Theirs",
        steps: [BuddyRoutine.step(:message_partner, { to: "x", message: "y" })],
      )

      get :index

      expect(response.parsed_body["routines"]).to be_empty
    end
  end

  describe "PATCH #update" do
    it "renames one" do
      routine = routine!("Nightly")

      patch :update, params: { id: routine.id, routine: { name: "Bedtime" } }

      expect(response).to be_successful
      expect(routine.reload.name).to eq("Bedtime")
    end

    it "turns one off without losing it" do
      routine = routine!("Nightly")

      patch :update, params: { id: routine.id, routine: { enabled: false } }

      expect(routine.reload.enabled).to be(false)
      expect(routine.steps).to be_present
    end

    # Steps come from save_routine, which validates them. Letting the panel post
    # raw steps would be a way around that check.
    it "ignores steps posted from the panel" do
      routine = routine!("Nightly")
      before  = routine.steps

      patch :update, params: { id: routine.id, routine: { name: "Bedtime", steps: [] } }

      expect(routine.reload.steps).to eq(before)
    end

    it "can't reach someone else's" do
      theirs = BuddyRoutine.create!(
        user:  create(:user),
        name:  "Theirs",
        steps: [BuddyRoutine.step(:message_partner, { to: "x", message: "y" })],
      )

      patch :update, params: { id: theirs.id, routine: { name: "Mine" } }

      expect(response).not_to be_successful
      expect(theirs.reload.name).to eq("Theirs")
    end
  end

  describe "DELETE #destroy" do
    it "removes it" do
      routine = routine!("Nightly")

      delete :destroy, params: { id: routine.id }

      expect(response).to have_http_status(:no_content)
      expect(BuddyRoutine.exists?(routine.id)).to be(false)
    end
  end

  # The Quick grid in the hero. Its order is one fact rather than N independent
  # ones, so the whole thing is sent at once: pinning is that list plus one,
  # unpinning is it minus one, and a drag is the new order.
  describe "POST #reorder" do
    it "pins in the order given" do
      a = routine!("Alpha")
      b = routine!("Beta")

      post :reorder, params: { ids: [b.id, a.id] }

      expect(response).to be_successful
      expect([b.reload.position, a.reload.position]).to eq([0, 1])
    end

    it "unpins anything left out" do
      a = routine!("Alpha")
      b = routine!("Beta")
      post :reorder, params: { ids: [a.id, b.id] }

      post :reorder, params: { ids: [a.id] }

      expect(a.reload.position).to eq(0)
      expect(b.reload.position).to be_nil
    end

    it "clears the whole grid when nothing is sent" do
      a = routine!("Alpha")
      post :reorder, params: { ids: [a.id] }

      post :reorder, params: { ids: [] }

      expect(a.reload.position).to be_nil
    end

    it "refuses to pin someone else's" do
      theirs = BuddyRoutine.create!(
        user:  create(:user),
        name:  "Theirs",
        steps: [BuddyRoutine.step(:message_partner, { to: "x", message: "y" })],
      )

      post :reorder, params: { ids: [theirs.id] }

      expect(theirs.reload.position).to be_nil
    end
  end

  describe "POST #run" do
    let(:partner) { create(:user) }
    let(:household) { user.chore_household || ChoreHousehold.create!(name: "Home", owner_user: user) }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(::WebPushNotifications).to receive(:update_count)
      ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
      user.update!(chore_household_id: household.id)
      partner.update!(chore_household_id: household.id)
      partner.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    def nightly!
      BuddyRoutine.create!(
        user:  user,
        name:  "Nightly",
        steps: [BuddyRoutine.step(:message_partner, { to: partner.username, message: "night" })],
      )
    end

    # A tapped routine is already decided, so spending a model round trip on
    # having it re-said costs money and reintroduces the one thing a saved
    # sequence removes - a different answer each time.
    it "runs the steps without a model turn" do
      routine = nightly!

      expect(BuddyDeliverWorker).not_to receive(:perform_async)
      post :run, params: { id: routine.id, conversation_id: convo.id }

      expect(response).to be_successful
      expect(BuddyRelay.last.body).to eq("night")
      expect(routine.reload.run_count).to eq(1)
    end

    # The line is the pet's own (Buddy::VoiceLines), so it's asserted as "one of
    # the things this theme says" rather than pinned to one phrasing — but it
    # always names the routine, which is the part that has to be there.
    it "hangs the steps under a line saying what ran" do
      routine = nightly!

      post :run, params: { id: routine.id, conversation_id: convo.id }

      said = convo.byte_messages.pluck(:body)
      expect(said).to include(a_string_including("**Nightly**"))
      expect(said).to include(a_string_matching(one_of(:routine_run, convo.buddy_theme, name: "Nightly")))
    end

    # A bare heading over nothing reads as the routine having worked.
    it "says so on the same message when nothing in it could run" do
      routine = routine!("Nightly") # targets a name nobody in the household has

      post :run, params: { id: routine.id, conversation_id: convo.id }

      expect(convo.byte_messages.last.body).to match(one_of(:routine_empty, convo.buddy_theme))
    end

    it "refuses one that's turned off" do
      routine = BuddyRoutine.create!(user: user, name: "Nightly", enabled: false, steps: [BuddyRoutine.step(:message_partner, { to: partner.username, message: "night" })])

      post :run, params: { id: routine.id, conversation_id: convo.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(routine.reload.run_count).to eq(0)
    end

    it "needs a conversation that's really theirs" do
      routine = routine!("Nightly")
      theirs  = create(:user).byte_conversations.create!(mode: :buddy, name: "Buddy")

      post :run, params: { id: routine.id, conversation_id: theirs.id }

      expect(response).to have_http_status(:not_found)
    end
  end
end
