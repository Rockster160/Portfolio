require "rails_helper"

# The five call sites that used to add a list item and let Jil task 382 turn
# that into "the chore is due".
#
# 382 ran uphill (list item -> chore) and the cascade only runs down, so it's
# gone. These tasks now mark the chore due themselves and the chore -> list item
# link pushes the item back onto the list. Same outcome, one arrow — but only if
# the rewritten Jil actually does that, which is what this pins.
#
# One-off in spirit; kept because the pairing between "what the task does" and
# "what the link does" is the whole point and neither half is obvious alone.
RSpec.describe "marking the chore due instead of adding the item" do
  let(:user)      { User.me }
  let(:household) { user.chore_household }

  def chore!(name)
    Chore.create!(chore_household: household, created_by_user: user, name: name)
  end

  def list!(name)
    List.create!(name: name).tap { |l| UserList.create!(user: user, list: l, is_owner: true) }
  end

  def link!(chore, item, list)
    RecordLink.create!(
      user: user, source_kind: :chore, source_name: chore,
      target_kind: :list_item, target_name: item, target_scope: list
    )
  end

  def run_jil(code)
    Jil::Executor.call(user, code)
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    allow(ChoreBroadcaster).to receive(:broadcast_changes!)
    RecordLink.delete_all
    Chore.where(chore_household: household).delete_all
    List.where(name: ["Todo", "Chores"]).find_each(&:destroy!)
    RecordLinks::Guard.reset!
  end

  # Task 22 (Wednesday cron) and 62 (Thursday cron) are the same shape.
  describe "a cron that used to add the item" do
    it "marks the chore due, and the link puts the item on the list" do
      chore = chore!("Take trash cans out")
      list  = list!("Todo")
      link!("Take trash cans out", "Take Trash Out", "Todo")

      run_jil('r5c69 = Chore.mark_due("Take trash cans out")::Chore')

      expect(chore.reload).to be_marked_due
      expect(list.reload.list_items.map(&:name)).to include("Take Trash Out")
    end

    it "names the chore, not the item — they differ on most of these" do
      chore = chore!("Bring trash cans in")
      list  = list!("Todo")
      link!("Bring trash cans in", "Bring in garbage cans", "Todo")

      run_jil('cafd8 = Chore.mark_due("Bring trash cans in")::Chore')

      expect(chore.reload).to be_marked_due
      expect(list.reload.list_items.map(&:name)).to include("Bring in garbage cans")
    end

    it "handles the two-chore variant (task 64)" do
      filter = chore!("Replace Air Filter")
      salt   = chore!("Check Softener Salt")
      list   = list!("Chores")
      link!("Replace Air Filter", "Change Air Filter", "Chores")
      link!("Check Softener Salt", "Check Salt", "Chores")

      run_jil(<<~JIL)
        cb1cc = Chore.mark_due("Replace Air Filter")::Chore
        h2d1b = Chore.mark_due("Check Softener Salt")::Chore
      JIL

      expect(filter.reload).to be_marked_due
      expect(salt.reload).to be_marked_due
      expect(list.reload.list_items.map(&:name)).to include("Change Air Filter", "Check Salt")
    end

    # The old code was idempotent by accident (mark_due no-ops when already
    # stamped). It still needs to be, because a cron can double-fire.
    it "doesn't stack items when run twice" do
      chore!("Take trash cans out")
      list = list!("Todo")
      link!("Take trash cans out", "Take Trash Out", "Todo")

      2.times { run_jil('r5c69 = Chore.mark_due("Take trash cans out")::Chore') }

      expect(list.reload.list_items.where(name: "Take Trash Out").count).to eq(1)
    end
  end

  describe "the RefillDrinks button (task 263)" do
    let!(:chore) { chore!("Restock Soda") }
    let!(:list)  { list!("Todo") }

    before { link!("Restock Soda", "Refill Drinks", "Todo") }

    it "button 1 marks it due and the item appears" do
      run_jil('cd_due = Chore.mark_due("Restock Soda")::Chore')

      expect(chore.reload).to be_marked_due
      expect(list.reload.list_items.map(&:name)).to include("Refill Drinks")
    end

    # The explicit List.list_remove came out of the task — completing the chore
    # is what takes the item off now, and doing both would be two writes racing
    # to the same place.
    it "button 2 completes it and the item goes without an explicit remove" do
      run_jil('cd_due = Chore.mark_due("Restock Soda")::Chore')
      expect(list.reload.list_items.map(&:name)).to include("Refill Drinks")

      run_jil('cc_d1 = Chore.complete("Restock Soda", {})::Any')

      expect(list.reload.list_items.map(&:name)).not_to include("Refill Drinks")
    end
  end

  describe "the Refill Protein button (task 279)" do
    let!(:chore) { chore!("Restock Protein") }
    let!(:list)  { list!("Todo") }

    # The old task added "Refill Protein" while the map expected "Refill Protein
    # Drinks", so that pairing never matched and the item never came off. The
    # link owns the item name now, which is what fixes it.
    before { link!("Restock Protein", "Refill Protein Drinks", "Todo") }

    it "puts the item on under the name the link actually uses" do
      run_jil('cd_due = Chore.mark_due("Restock Protein")::Chore')

      expect(list.reload.list_items.map(&:name)).to include("Refill Protein Drinks")
      expect(list.reload.list_items.map(&:name)).not_to include("Refill Protein")
    end

    # Button 2 doesn't complete anything directly — it raises the who-did-it
    # prompt, and RecordLinks::Propagator completes the chore when that comes
    # back, which then takes the item off.
    it "clears the item once the who-did-it prompt is answered" do
      run_jil('cd_due = Chore.mark_due("Restock Protein")::Chore')
      Prompt.where(user_id: user.id).delete_all
      prompt = user.prompts.create!(
        question: "Who restocked protein?",
        params:   { source: "ambiguous_chore", chore_name: "Restock Protein" },
        options:  [{ type: :select, question: "Who did it?", choices: [user.username], default: "" }],
        response: { "Who did it?" => user.username },
      )

      Jil::Executor.trigger(user, :prompt, prompt.with_jil_attrs(status: :complete))

      expect(chore.reload.chore_completions.count).to eq(1)
      expect(list.reload.list_items.map(&:name)).not_to include("Refill Protein Drinks")
    end
  end

  # The rule these rewrites exist to satisfy.
  it "no longer lets a hand-added list item mark a chore due" do
    chore = chore!("Restock Soda")
    list  = list!("Todo")
    link!("Restock Soda", "Refill Drinks", "Todo")

    list.list_items.add("Refill Drinks")

    expect(chore.reload).not_to be_marked_due
  end
end
