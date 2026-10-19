require "rails_helper"

# A board's own chat: the pet on a board, set up by talking to it. The board
# tools exist only on a board's thread, and every change they make unticks
# back off.
RSpec.describe "Buddy board tools" do
  let(:user) { create(:user, username: "boardowner") }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let(:partner) { create(:user, username: "zelie") }
  let(:board) {
    user.byte_conversations.create!(
      mode:            :buddy,
      name:            "Kitchen",
      last_message_at: Time.current,
      metadata:        { "board" => true, "chore_tags" => ["Kitchen"] },
    )
  }
  let(:chat) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before {
    user.update!(chore_household_id: household.id)
    partner.update!(chore_household_id: household.id)
    ChoreHouseholdMembership.create!(chore_household: household, user: partner)
  }

  def run(name, payload, conversation: board)
    tool = Buddy::Tools[name]
    ctx  = Buddy::ToolContext.new(user, conversation: conversation)
    resolved = payload.merge(tool[:confirm].call(payload, ctx)[:resolved])
    tool[:execute].call(resolved, Buddy::ToolContext.new(user, conversation: conversation))
  end

  def undo(result)
    Buddy::Reverter.call(result[:revert].deep_stringify_keys)
  end

  describe "where they're offered" do
    let(:board_tools) { %i[pin_chore unpin_chore add_credit_button set_board_groups] }

    it "offers them in full on a board's own chat and nowhere else" do
      on_board = Buddy::ToolIndex.schemas(user: user, conversation: board)
      elsewhere = Buddy::ToolIndex.schemas(user: user, conversation: chat)

      board_tools.each { |name|
        schema = on_board.find { |s| s[:name] == name }
        expect(schema[:parameters][:properties]).to be_present, "#{name} should be offered in full"
      }
      expect(elsewhere.pluck(:name) & board_tools).to eq([])
    end

    it "refuses one that arrives off a board" do
      tool = Buddy::Tools[:pin_chore]
      call = { name: "pin_chore", arguments: { chore: "Dishes" }.to_json }
      output, = Buddy::GPT::Turn.resolve_call(tool, call, user: user, conversation: chat)

      expect(output.to_s).to include("only works from a board's own chat")
    end
  end

  describe "pin_chore / unpin_chore" do
    let!(:litter) { household.chores.create!(created_by_user: user, name: "Litter box", tags: ["Pets"]) }

    it "pins a chore to the board it's said on, and undoes it" do
      result = run(:pin_chore, { chore: "litter" })

      expect(board.reload.pinned_chore_ids).to eq([litter.id])
      undo(result)
      expect(board.reload.pinned_chore_ids).to eq([])
    end

    it "takes a pin off, and refuses one that isn't pinned" do
      board.update!(pinned_chore_ids: [litter.id])

      result = run(:unpin_chore, { chore: "litter" })
      expect(board.reload.pinned_chore_ids).to eq([])

      undo(result)
      expect(board.reload.pinned_chore_ids).to eq([litter.id])

      household.chores.create!(created_by_user: user, name: "Dishes")
      expect { run(:unpin_chore, { chore: "dishes" }) }.to raise_error(/isn't pinned here/)
    end

    it "leaves the rest of the board's settings alone on undo" do
      result = run(:pin_chore, { chore: "litter" })
      board.update!(metadata: board.metadata.merge("chore_dreams" => false))

      undo(result)

      expect(board.reload.chore_dreams?).to be(false)
      expect(board.chore_tags).to eq(["Kitchen"])
    end
  end

  describe "add_credit_button" do
    let!(:dishes) { household.chores.create!(created_by_user: user, name: "Dishes") }

    it "files a button under the board's groups, crediting who they named, and undoes it" do
      result = run(:add_credit_button, { chore: "dishes", credit: "Zelie" })
      button = ChoreCreditButton.find(result[:button_id])

      expect(button.slice(:label, :tags, :credit_user_id, :chore_id))
        .to eq("label" => "Dishes, Zelie", "tags" => ["Kitchen"], "credit_user_id" => partner.id, "chore_id" => dishes.id)

      undo(result)
      expect(ChoreCreditButton.exists?(button.id)).to be(false)
    end

    it "makes a whoever-did-it button" do
      result = run(:add_credit_button, { chore: "dishes", credit: "whoever", label: "Dishes" })

      expect(ChoreCreditButton.find(result[:button_id]).credit_user_id).to be_nil
    end

    it "refuses somebody who isn't in the house" do
      expect { run(:add_credit_button, { chore: "dishes", credit: "Zelda" }) }.to raise_error(/no household member/)
    end
  end

  describe "set_board_groups" do
    it "sets the whole list and puts the old one back on undo" do
      result = run(:set_board_groups, { groups: "Kitchen, Pets" })
      expect(board.reload.chore_tags).to eq(%w[Kitchen Pets])

      undo(result)
      expect(board.reload.chore_tags).to eq(["Kitchen"])
    end
  end

  describe "chores made from a board" do
    it "files a new chore under the board's groups unless told otherwise" do
      result = run(:create_chore, { name: "Wipe the counters" })
      expect(Chore.find(result[:chore_id]).tags).to eq(["Kitchen"])

      result = run(:create_chore, { name: "Brush the cat", groups: "Pets" })
      expect(Chore.find(result[:chore_id]).tags).to eq(["Pets"])

      result = run(:create_chore, { name: "Call the bank" }, conversation: chat)
      expect(Chore.find(result[:chore_id]).tags).to eq([])
    end

    it "regroups a chore with edit_chore, and undoes it" do
      chore = household.chores.create!(created_by_user: user, name: "Sweep", tags: ["Hall"])

      result = run(:edit_chore, { chore: "sweep", groups: "Kitchen, Hall" })
      expect(chore.reload.tags).to eq(%w[Kitchen Hall])

      undo(result)
      expect(chore.reload.tags).to eq(["Hall"])

      run(:edit_chore, { chore: "sweep", groups: "none" })
      expect(chore.reload.tags).to eq([])
    end
  end

  describe "what the pet is told" do
    it "describes the board it's on, only on a board" do
      dishes = household.chores.create!(created_by_user: user, name: "Dishes")
      board.update!(pinned_chore_ids: [dishes.id])

      prompt = Buddy::Personality.for(user, conversation: board)

      expect(prompt).to include("## This board", "**Kitchen**", "Groups it watches:** Kitchen", "Pinned chores", "Dishes")
      expect(Buddy::Personality.for(user, conversation: chat)).not_to include("## This board")
    end
  end
end
