require "rails_helper"

# Reproduction of prod tasks 381 (List Chore Item Map) + 382 (List Item ->
# Mark Chore Due) to diagnose why an "item:action::added" of "Pickup RX"
# did not mark the "Pickup RX" chore due.
RSpec.describe "Pickup RX list-item -> chore mark_due", type: :service do
  let(:user) { create(:user) }
  let!(:chore) {
    create(:chore, name: "Pickup RX", short_name: "Pickup RX", created_by_user: user)
  }

  let!(:map_task) {
    user.tasks.create!(
      name:     "List Chore Item Map",
      listener: "function()::Hash",
      enabled:  true,
      code:     <<~'JIL',
        m = Hash.new({
          pr = Keyval.keyHash("Check Softener Salt", {
            pr_l = Hash.keyval("list", "Chores")::Keyval
            pr_i = Hash.keyval("item", "Check Salt")::Keyval
          })::Keyval
          j62d4 = Keyval.keyHash("Replace Air Filter", {
            j62d4_l = Hash.keyval("list", "Chores")::Keyval
            j62d4_i = Hash.keyval("item", "Change Air Filter")::Keyval
          })::Keyval
          u3d3b = Keyval.keyHash("Go get mail", {
            u3d3b_l = Hash.keyval("list", "Chores")::Keyval
            u3d3b_i = Hash.keyval("item", "Get the Mail")::Keyval
          })::Keyval
          z4a03 = Keyval.keyHash("Pickup RX", {
            z4a03_l = Hash.keyval("list", "Chores")::Keyval
            z4a03_i = Hash.keyval("item", "Pickup RX")::Keyval
          })::Keyval
          rs = Keyval.keyHash("Bring trash cans in", {
            rs_l = Hash.keyval("list", "Todo")::Keyval
            rs_i = Hash.keyval("item", "Bring in garbage cans")::Keyval
          })::Keyval
          z48e7 = Keyval.keyHash("Take trash cans out", {
            z48e7_l = Hash.keyval("list", "Todo")::Keyval
            z48e7_i = Hash.keyval("item", "Take Trash Out")::Keyval
          })::Keyval
          q2371 = Keyval.keyHash("Restock Soda", {
            q2371_l = Hash.keyval("list", "Todo")::Keyval
            q2371_i = Hash.keyval("item", "Refill Drinks")::Keyval
          })::Keyval
          rp = Keyval.keyHash("Restock Protein", {
            rp_l = Hash.keyval("list", "Todo")::Keyval
            rp_i = Hash.keyval("item", "Refill Protein Drinks")::Keyval
          })::Keyval
          cymb = Keyval.keyHash("Cymbalta", {
            cymb_l = Hash.keyval("list", "Todo")::Keyval
            cymb_i = Hash.keyval("item", "Cymbalta")::Keyval
          })::Keyval
        fae_food = Keyval.keyHash("Refill Fae Food", {
          fae_food_l = Hash.keyval("list", "Fae Chores")::Keyval
          fae_food_i = Hash.keyval("item", "Refill Fae Food")::Keyval
        })::Keyval
        fae_lit = Keyval.keyHash("Kitty Litter", {
          fae_lit_l = Hash.keyval("list", "Fae Chores")::Keyval
          fae_lit_i = Hash.keyval("item", "Kitty Litter")::Keyval
        })::Keyval
        fae_gen = Keyval.keyHash("Take out Kitty Genie Bag", {
          fae_gen_l = Hash.keyval("list", "Fae Chores")::Keyval
          fae_gen_i = Hash.keyval("item", "Take out Kitty Genie Bag")::Keyval
        })::Keyval
        fae_pro = Keyval.keyHash("Fae Probiotic", {
          fae_pro_l = Hash.keyval("list", "Fae Chores")::Keyval
          fae_pro_i = Hash.keyval("item", "Fae Probiotic")::Keyval
        })::Keyval
        fae_vl = Keyval.keyHash("Deep Clean Cat Area", {
          fae_vl_l = Hash.keyval("list", "Fae Chores")::Keyval
          fae_vl_i = Hash.keyval("item", "Deep Clean Cat Area")::Keyval
        })::Keyval
        fae_vm = Keyval.keyHash("Vacuum Litter Mat", {
          fae_vm_l = Hash.keyval("list", "Fae Chores")::Keyval
          fae_vm_i = Hash.keyval("item", "Vacuum Litter Mat")::Keyval
        })::Keyval
        fae_wipe = Keyval.keyHash("Fae Wipe", {
          fae_wipe_l = Hash.keyval("list", "Fae Chores")::Keyval
          fae_wipe_i = Hash.keyval("item", "Fae Wipe")::Keyval
        })::Keyval
        fae_muti = Keyval.keyHash("Fae Muti", {
          fae_muti_l = Hash.keyval("list", "Fae Chores")::Keyval
          fae_muti_i = Hash.keyval("item", "Fae Muti")::Keyval
        })::Keyval
        })::Hash
        ret = Global.return(m)::Hash
      JIL
    )
  }

  let(:task_382_code) {
    <<~'JIL'
      itemMap = Custom.ListChoreItemMap()::Hash
      data = Global.input_data()::Hash
      itemName = data.get("name")::String
      *loop = itemMap.each({
        *cond = Global.if({
          entry = Keyword.Value()::Hash
          entryItem = entry.get("item")::String
          isMatch = Boolean.compare(entryItem, "==", itemName)::Boolean
        }, {
          choreName = Keyword.Key()::String
          *chore = Chore.mark_due(choreName)::Chore
        }, {})::Any
      })::Hash
    JIL
  }

  it "map function returns a hash containing the Pickup RX entry" do
    ctx = Jil::Executor.call(user, map_task.code)
    map = ctx.ctx[:return_val]
    expect(map).to be_a(Hash)
    expect(map["Pickup RX"]).to eq({ "list" => "Chores", "item" => "Pickup RX" })
  end

  it "marks the Pickup RX chore due when the item is added" do
    expect(chore.marked_due_at).to be_nil

    Jil::Executor.call(user, task_382_code, {
      name:   "Pickup RX",
      action: "added",
      list:   { name: "Chores" },
    })

    expect(chore.reload.marked_due_at).to be_present
  end

  it "marks due even when the map task has CRLF line endings (prod byte-for-byte)" do
    map_task.update!(code: map_task.code.gsub("\n", "\r\n"))

    expect(chore.marked_due_at).to be_nil

    Jil::Executor.call(user, task_382_code, {
      name:   "Pickup RX",
      action: "added",
      list:   { name: "Chores" },
    })

    expect(chore.reload.marked_due_at).to be_present
  end

  it "SILENTLY does NOT mark due on a case mismatch (exact == compare)" do
    Jil::Executor.call(user, task_382_code, {
      name:   "pickup rx",
      action: "added",
      list:   { name: "Chores" },
    })

    expect(chore.reload.marked_due_at).to be_nil
  end

  it "SILENTLY does NOT mark due on trailing whitespace" do
    Jil::Executor.call(user, task_382_code, {
      name:   "Pickup RX ",
      action: "added",
      list:   { name: "Chores" },
    })

    expect(chore.reload.marked_due_at).to be_nil
  end

  it "marks due via the real Task#execute trigger path" do
    task_382 = user.tasks.create!(
      name:     "List Item → Mark Chore Due",
      listener: "item:action::added",
      enabled:  true,
      code:     task_382_code,
    )

    task_382.execute(
      { name: "Pickup RX", action: "added", list: { name: "Chores" } },
      trigger_scope: :item,
    )

    expect(chore.reload.marked_due_at).to be_present
  end
end
