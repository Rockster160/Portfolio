require "rails_helper"

# Prod 3509: "Also, the script was supposed to be darkness, NOT total darkness".
# Reply 3510: "Kk! I fixed the script wording to darkness." buddy_routines 4
# still read `scene: "total_darkness"` on step 2, with an updated_at identical
# to its created_at — nothing had written to the row since it was made. Both
# are real HASS scenes, so running lockdown ran the wrong one.
#
# save_routine's description already said, in those words, that saving over a
# name is how a routine gets fixed. The reason that wasn't enough is that it
# couldn't be followed: `routines` shows each step as a phrase ("call jil
# function: HASS Scene"), never its arguments, so re-saving the sequence from
# what the model can see silently drops every argument the phrase omits — here,
# the position the blinds close to. There was no way to change one value.
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
    it "writes the new value onto the step they named" do
      edit!(name: "shopping run", step: 2, set: '{"item":"sourdough"}')

      expect(steps[1]["payload"]["item"]).to eq("sourdough")
    end

    it "leaves every other step exactly as it was" do
      edit!(name: "shopping run", step: 2, set: '{"item":"sourdough"}')

      expect(steps[0]["payload"]).to eq("list" => "Groceries", "item" => "milk", "category" => "weekly")
    end

    # The argument nobody mentioned is also the one that can't be read back off
    # the summary phrase, so replacing the payload wholesale is exactly how a
    # correction quietly drops it.
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
  end

  describe "what it refuses" do
    def confirm(payload) = tool[:confirm].call(payload, ctx)

    it "refuses a routine that isn't theirs to edit" do
      expect { confirm(name: "wind down", step: 1, set: '{"item":"x"}') }
        .to raise_error(/no routine called/)
    end

    it "refuses a step number the routine doesn't have" do
      expect { confirm(name: "shopping run", step: 5, set: '{"item":"x"}') }
        .to raise_error(/has 2 steps, so there's no step 5/)
    end

    it "refuses step 0, since the model counts from 1" do
      expect { confirm(name: "shopping run", step: 0, set: '{"item":"x"}') }
        .to raise_error(/no step 0/)
    end

    it "refuses something that isn't a JSON object" do
      expect { confirm(name: "shopping run", step: 1, set: "item = milk") }
        .to raise_error(/JSON object/)
      expect { confirm(name: "shopping run", step: 1, set: "{}") }
        .to raise_error(/name at least one argument/)
    end

    # The same gate a fresh save goes through. A routine is the one thing where
    # a step that resolves to nothing is unaffordable, because nobody re-reads a
    # saved sequence — it fails the same way every time and looks like it ran.
    it "refuses a value that matches nothing of theirs, and writes nothing" do
      expect { edit!(name: "shopping run", step: 1, set: '{"list":"Kayaks"}') }
        .to raise_error(/no list matching/)
      expect(steps[0]["payload"]["list"]).to eq("Groceries")
    end
  end

  describe "what it tells them" do
    it "names the step and what it became" do
      result = edit!(name: "shopping run", step: 2, set: '{"item":"sourdough"}')

      expect(tool[:receipt].call(result.symbolize_keys, ctx)).to include("shopping run", "step 2", "sourdough")
    end

    it "shows the before and after on the chip" do
      resolved = tool[:confirm].call({ name: "shopping run", step: 2, set: '{"item":"sourdough"}' }, ctx)[:resolved]

      expect(tool[:label].call(resolved, ctx)[:sub]).to include("bread", "sourdough")
    end
  end

  # Editing a routine from inside a routine is a knot with no use case behind
  # it, and the same reason save_routine and forget_routine are excluded.
  it "can't be saved as a step of a routine" do
    expect(Buddy::Tools.routinable?(tool)).to be(false)
  end
end
