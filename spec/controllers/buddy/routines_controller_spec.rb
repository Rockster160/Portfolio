require "rails_helper"

# The drawer panel is deliberately read-mostly: steps are tool calls with
# validated arguments, which get written by talking to Byte. What lives here is
# the part conversation is bad at - seeing them all, fixing a name, muting one,
# throwing one away.
RSpec.describe Buddy::RoutinesController, type: :controller do
  let(:user) { User.me }

  before { sign_in user }

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
end
