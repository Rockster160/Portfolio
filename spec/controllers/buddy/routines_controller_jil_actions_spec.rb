require "rails_helper"

# Turning a Jil automation into a one-tap button.
#
# A Jil button IS a routine with one `trigger_jil_task` step - same record, same
# runner, same pin/order/mute/delete, and it lands on the Quick grid and the
# wall tablet with no separate handling. This is only here because getting one
# used to mean asking Buddy to save it, and there's nothing to discuss when the
# whole routine is "fire this".
RSpec.describe Buddy::RoutinesController, type: :controller do
  let(:user) { create(:user, id: 4) } # someone with Byte access

  before { sign_in user }

  def task!(name:, listener: "fan-high", description: "Puts the fan on high", **attrs)
    Task.create!(
      user: user, name: name, listener: listener, description: description,
      code: "", enabled: true, buddy_enabled: true, **attrs
    )
  end

  def actions
    response.parsed_body["actions"]
  end

  describe "GET #jil_actions" do
    it "offers an automation that fires by name alone" do
      task!(name: "Fan High")

      get :jil_actions

      expect(response).to be_successful
      expect(actions.pluck("name")).to eq(["Fan High"])
      expect(actions.first["description"]).to eq("Puts the fan on high")
    end

    # The filter that matters. A listener with data filters on it needs a
    # payload built to fire, and a button has nowhere to say what that payload
    # is — so offering one would produce a button that looks fine and quietly
    # never fires, which is the one failure a saved button must not have.
    it "leaves out one that needs data to fire" do
      task!(name: "Categorize", listener: "event:add name::Transaction")

      get :jil_actions

      expect(actions).to be_empty
    end

    it "leaves out one the owner hasn't opted in to Buddy" do
      task!(name: "Private", buddy_enabled: false)

      get :jil_actions

      expect(actions).to be_empty
    end

    it "stops offering one that already has a button" do
      t = task!(name: "Fan High")
      post :create, params: { task_id: t.id }

      get :jil_actions

      expect(actions).to be_empty
    end
  end

  describe "POST #create" do
    it "saves it as a one-step routine that fires the task" do
      t = task!(name: "Fan High")

      post :create, params: { task_id: t.id }

      expect(response).to have_http_status(:created)
      routine = user.buddy_routines.last
      expect(routine.name).to eq("Fan High")
      expect(routine.steps.length).to eq(1)
      expect(routine.steps.first["tool_name"]).to eq("trigger_jil_task")
      expect(routine.steps.first.dig("payload", "name")).to eq("Fan High")
    end

    it "takes a shorter label for the wall when one is given" do
      t = task!(name: "Printer - Preheat")

      post :create, params: { task_id: t.id, name: "Preheat" }

      expect(user.buddy_routines.last.name).to eq("Preheat")
    end

    # Every enabled routine is already on the Quick grid and the kiosk, so this
    # is the whole point: adding one here puts a button on the wall.
    it "lands on the wall pad straight away" do
      t = task!(name: "Fan High")

      post :create, params: { task_id: t.id }

      expect(user.buddy_routines.for_quick.map(&:name)).to include("Fan High")
    end

    it "refuses a second one under the same name" do
      t = task!(name: "Fan High")
      post :create, params: { task_id: t.id }

      post :create, params: { task_id: t.id, name: "fan high" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.buddy_routines.count).to eq(1)
    end

    it "refuses an automation that needs data" do
      t = task!(name: "Categorize", listener: "event:add name::Transaction")

      post :create, params: { task_id: t.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.buddy_routines).to be_empty
    end

    it "refuses someone else's automation" do
      other = create(:user)
      theirs = Task.create!(
        user: other, name: "Not Yours", listener: "fan-high", code: "", enabled: true, buddy_enabled: true,
      )

      post :create, params: { task_id: theirs.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.buddy_routines).to be_empty
    end
  end

  it "refuses anyone who can't open Byte at all" do
    sign_in create(:user)

    get :jil_actions

    expect(response).to have_http_status(:forbidden)
  end
end
