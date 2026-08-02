require "rails_helper"

# Making a chore, and changing one, run the moment Byte proposes them — a
# pre-checked row that unticks back off rather than an empty box waiting on a
# tap. They'd already asked for it, and a chore is both visible and reversible,
# so the confirmation was a toll on the common case.
#
# The row is only honest if the undo works, which is the half these cover: a
# chore was never in Buddy::Reverter at all before this, so "level 2" without
# teaching it about chores would have been a promise nothing could keep.
RSpec.describe "Buddy chore writes" do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo)     {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(::Jil).to receive(:trigger).and_return(true)
    user.update!(chore_household_id: household.id)
  }

  def propose!(marker)
    msg = convo.byte_messages.create!(
      user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
    )
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: [marker])
  end

  def untick!(result)
    action = result[:action]
    Buddy::ProposalExecutor.undo!(action.id, action.buttons.first["id"])
  end

  describe "making one" do
    it "exists without anyone tapping anything" do
      expect { propose!({ tool_name: :create_chore, payload: { name: "Dust shelves" } }) }
        .to change { household.chores.where(name: "Dust shelves").count }.by(1)
    end

    it "leaves a row that's already ticked, and can be unticked" do
      row = propose!({ tool_name: :create_chore, payload: { name: "Dust shelves" } })[:action].buttons.first

      expect(row["status"]).to eq("executed")
      expect(row["undoable"]).to be(true)
    end

    # Archived, not destroyed. A chore owns its completions and its streak
    # history, and undoing "you just made this" mustn't take a month of someone's
    # record with it — the Chores app archives for "delete" too.
    it "archives it rather than destroying it when unticked" do
      result = propose!({ tool_name: :create_chore, payload: { name: "Dust shelves" } })

      untick!(result)

      chore = household.chores.find_by(name: "Dust shelves")
      expect(chore).to be_present
      expect(chore).to be_archived
    end
  end

  describe "changing one" do
    let!(:chore) { create(:chore, name: "Vacuum", created_by_user: user) }

    it "lands the change on arrival" do
      propose!({ tool_name: :edit_chore, payload: { chore: "Vacuum", name: "Hoover" } })

      expect(chore.reload.name).to eq("Hoover")
    end

    it "puts the old values back when unticked" do
      result = propose!({ tool_name: :edit_chore, payload: { chore: "Vacuum", name: "Hoover" } })

      untick!(result)

      expect(chore.reload.name).to eq("Vacuum")
    end

    # Archiving through the edit tool is still an edit, so unticking has to
    # un-archive rather than leaving it hidden.
    it "brings one back that the edit archived" do
      result = propose!({ tool_name: :edit_chore, payload: { chore: "Vacuum", disabled: "true" } })
      expect(chore.reload).to be_archived

      untick!(result)

      expect(chore.reload).not_to be_archived
    end
  end
end
