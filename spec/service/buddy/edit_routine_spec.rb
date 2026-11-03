require "rails_helper"

# `routines` shows each step as a phrase, never its arguments, so re-saving a
# sequence from what the model can see drops every argument the phrase omits.
# edit_routine changes one value on one step and leaves the rest.
RSpec.describe "edit_routine" do
  let(:user)  { create(:user) }
  let!(:list) { List.create!(name: "Groceries").tap { |l| UserList.create!(user: user, list: l) } }
  let!(:other_list) { List.create!(name: "Hardware").tap { |l| UserList.create!(user: user, list: l) } }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }
  let(:tool) { Buddy::Tools[:edit_routine] }

  let!(:routine) {
    user.buddy_routines.create!(
      name:  "shopping run",
      steps: [
        BuddyRoutine.step(:add_list_item, { list: "Groceries", item: "milk", category: "weekly" }),
        BuddyRoutine.step(:add_list_item, { list: "Groceries", item: "bread" }),
      ],
    )
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def edit!(payload)
    tool[:execute].call(payload.merge(tool[:confirm].call(payload, ctx)[:resolved]), ctx)
  end

  def steps = routine.reload.steps

  describe "changing one value" do
    it "writes the new value onto the step they named and leaves every other step as it was" do
      edit!(name: "shopping run", step: 2, set: '{"item":"sourdough"}')

      expect(steps[1]["payload"]["item"]).to eq("sourdough")
      expect(steps[0]["payload"]).to eq("list" => "Groceries", "item" => "milk", "category" => "weekly")
    end

    # Replacing the payload wholesale is how a correction quietly drops the
    # argument nobody mentioned.
    it "keeps the arguments of that step that weren't named" do
      edit!(name: "shopping run", step: 1, set: '{"item":"oat milk"}')

      expect(steps[0]["payload"]).to eq("list" => "Groceries", "item" => "oat milk", "category" => "weekly")
    end

    it "can change more than one argument at once" do
      edit!(name: "shopping run", step: 1, set: '{"item":"nails","list":"Hardware"}')

      expect(steps[0]["payload"]).to include("item" => "nails", "list" => "Hardware")
    end

    it "matches the routine name loosely, like every other routine tool" do
      expect { edit!(name: "shopping", step: 1, set: '{"item":"oat milk"}') }
        .to change { steps[0]["payload"]["item"] }.to("oat milk")
    end

    it "shows the before and after on the chip" do
      resolved = tool[:confirm].call({ name: "shopping run", step: 2, set: '{"item":"sourdough"}' }, ctx)[:resolved]

      expect(tool[:label].call(resolved, ctx)[:sub]).to include("bread", "sourdough")
    end
  end

  describe "what it refuses" do
    def confirm(payload) = tool[:confirm].call(payload, ctx)

    it "refuses a routine that isn't theirs, a step it doesn't have, and a set that isn't a JSON object" do
      expect { confirm(name: "wind down", step: 1, set: '{"item":"x"}') }.to raise_error(/no routine called/)
      expect { confirm(name: "shopping run", step: 5, set: '{"item":"x"}') }.to raise_error(/no step 5/)
      # The model counts from 1.
      expect { confirm(name: "shopping run", step: 0, set: '{"item":"x"}') }.to raise_error(/no step 0/)
      expect { confirm(name: "shopping run", step: 1, set: "item = milk") }.to raise_error(/JSON object/)
      expect { confirm(name: "shopping run", step: 1, set: "{}") }.to raise_error(/at least one argument/)
    end

    # The same gate a fresh save goes through: nobody re-reads a saved
    # sequence, so a step that resolves to nothing fails silently every time.
    it "refuses a value that matches nothing of theirs, and writes nothing" do
      expect { edit!(name: "shopping run", step: 1, set: '{"list":"Kayaks"}') }
        .to raise_error(/no list matching/)
      expect(steps[0]["payload"]["list"]).to eq("Groceries")
    end

    # Rewriting the identical payload and calling it fixed hides that the fault
    # is somewhere else.
    describe "an edit that would change nothing" do
      it "refuses rather than writing the same values again, leaving updated_at alone" do
        was = routine.updated_at

        expect { edit!(name: "shopping run", step: 1, set: '{"item":"milk"}') }.to raise_error(/already set/)
        expect(routine.reload.updated_at).to eq(was)
      end

      it "still allows repeating one value while changing another, or copying a different step" do
        edit!(name: "shopping run", step: 1, set: '{"list":"Groceries","item":"oat milk"}')
        expect(steps[0]["payload"]).to eq("list" => "Groceries", "item" => "oat milk", "category" => "weekly")

        edit!(name: "shopping run", step: 2, set: '{"item":"oat milk"}')
        expect(steps[1]["payload"]["item"]).to eq("oat milk")
      end
    end
  end
end
