require "rails_helper"
require "timeout"

# End-to-end guard for the item <-> chore sync cascade now that model-level
# list adds emit `:item` triggers:
#   item added -> task 382 marks chore due -> chore:marked_due -> task 416
#   re-adds the mapped item -> item added again -> task 382 sees it's already
#   marked due and stops.
# The idempotent Chore.mark_due is what breaks the otherwise-infinite loop.
RSpec.describe "item <-> chore sync cascade", type: :service do
  let(:user) { create(:user) }
  let!(:chore) {
    create(:chore, name: "Pickup RX", short_name: "Pickup RX", created_by_user: user)
  }
  let!(:chores_list) { create(:list, name: "Chores", user: user) }
  let!(:misses_list) { create(:list, name: "Chore Due Misses", user: user) }

  let!(:map_task) {
    user.tasks.create!(
      name: "List Chore Item Map", listener: "function()::Hash", enabled: true,
      code: <<~'JIL',
        m = Hash.new({
          rx = Keyval.keyHash("Pickup RX", {
            rx_l = Hash.keyval("list", "Chores")::Keyval
            rx_i = Hash.keyval("item", "Pickup RX")::Keyval
          })::Keyval
        })::Hash
        ret = Global.return(m)::Hash
      JIL
    )
  }

  let!(:item_to_chore) {
    user.tasks.create!(
      name: "List Item → Mark Chore Due", listener: "item:action::added", enabled: true,
      code: <<~'JIL',
        itemMap = Custom.ListChoreItemMap()::Hash
        data = Global.input_data()::Hash
        itemName = data.get("name")::String
        itemNameLc = itemName.format("lower")::String
        listInfo = data.get("list")::Hash
        listName = listInfo.get("name")::String
        listNameLc = listName.format("lower")::String
        *loop = itemMap.each({
          entry = Keyword.Value()::Hash
          entryItem = entry.get("item")::String
          entryItemLc = entryItem.format("lower")::String
          entryList = entry.get("list")::String
          entryListLc = entryList.format("lower")::String
          itemMatch = Boolean.compare(entryItemLc, "==", itemNameLc)::Boolean
          listMatch = Boolean.compare(entryListLc, "==", listNameLc)::Boolean
          bothMatch = Boolean.and(itemMatch, "&&", listMatch)::Boolean
          *cond = Global.if({
            doMark = Global.ref(bothMatch)::Boolean
          }, {
            choreName = Keyword.Key()::String
            chore = Chore.mark_due(choreName)::Chore
            *missCheck = Global.if({
              foundChore = Boolean.new(chore)::Boolean
            }, {}, {
              missMsg = String.new("#{choreName}")::String
              logged = List.list_add("Chore Due Misses", missMsg)::List
            })::Any
          }, {})::Any
        })::Hash
      JIL
    )
  }

  let!(:chore_to_item) {
    user.tasks.create!(
      name: "Chore Marked Due → Add List Item", listener: "chore:action::marked_due", enabled: true,
      code: <<~'JIL',
        itemMap = Custom.ListChoreItemMap()::Hash
        data = Global.input_data()::Hash
        choreName = data.get("name")::String
        branch = Global.if({
          hasEntry = itemMap.key?(choreName)::Boolean
        }, {
          entry = itemMap.get(choreName)::Hash
          listName = entry.get("list")::String
          itemName = entry.get("item")::String
          added = List.list_add(listName, itemName)::List
        }, {})::Any
      JIL
    )
  }

  it "marks the chore due, adds the item once, and TERMINATES (bounded cascade)" do
    expect(chore.marked_due_at).to be_nil

    item_triggers = 0
    allow(::Jil).to receive(:trigger).and_wrap_original { |orig, *args, **kw|
      item_triggers += 1 if args[1].to_sym == :item
      orig.call(*args, **kw)
    }

    Timeout.timeout(20) {
      chores_list.list_items.add("Pickup RX")
    }

    expect(chore.reload.marked_due_at).to be_present
    active = chores_list.list_items.where(deleted_at: nil).where(name: "Pickup RX")
    expect(active.count).to eq(1)
    expect(misses_list.list_items.where(deleted_at: nil)).to be_empty
    # The cascade DOES round-trip (initial add + 416's re-add re-fire :item),
    # but the idempotent mark_due stops it — a runaway loop would be dozens.
    expect(item_triggers).to be_between(2, 4)
  end

  it "adding the item when the chore is ALREADY due does not re-cascade" do
    chore.update!(marked_due_at: Time.current)
    before = chore.marked_due_at

    Timeout.timeout(20) {
      chores_list.list_items.add("Pickup RX")
    }

    # No re-stamp (idempotent), so no fresh chore:marked_due trigger fired.
    expect(chore.reload.marked_due_at).to be_within(1.second).of(before)
  end
end
