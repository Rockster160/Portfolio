require "rails_helper"

# The blanket mirror between the chores that are DUE and the "Chores" list.
#
# Narrower than the Today tab on purpose: due today plus overdue carryover, and
# nothing that merely sits on Today (a Dailies pin, a `show_on_today_view:
# always` chore with no schedule). A chore done or skipped today drops out.
#
# The two halves are separate hazards and both are pinned below: the mirror's
# own writes fire the same `:item` triggers a person's tap does, so without the
# writing flag a removal made BECAUSE a chore was completed comes back round as
# "the item was ticked, complete the chore."
RSpec.describe ChoreListSync do
  let(:user)      { User.me }
  let(:household) { user.chore_household }
  let!(:list)     { List.create!(name: "Chores").tap { |l| UserList.create!(user: user, list: l, is_owner: true) } }
  let(:day)       { ChoreDay.current(user) }

  def chore!(name, **attrs)
    Chore.create!({
      chore_household:    household,
      created_by_user:    user,
      name:               name,
      show_on_today_view: :when_scheduled,
    }.merge(attrs))
  end

  def item_names
    list.reload.list_items.ordered.map(&:name)
  end

  # Straight through the model, so `notify_jil` fires and the whole bus runs
  # rather than the service being poked directly.
  def type_item!(name)
    list.list_items.add(name)
  end

  def tick_item!(name)
    list.list_items.remove(name)
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    allow(ChoreBroadcaster).to receive(:broadcast_changes!)
    allow(ChoreBroadcaster).to receive(:broadcast_hot_picks_refreshed!)
    # The mirror enqueues itself off every chore write. Running it inline is
    # what makes these examples about the reconcile instead of about Sidekiq.
    allow(ChoreListSyncWorker).to receive(:perform_async) { |id| ChoreListSyncWorker.new.perform(id) }
    RecordLink.delete_all
    ChoreCompletion.where(user_id: user.id).delete_all
    Chore.where(chore_household: household).delete_all
    list.list_items.with_deleted.delete_all
    RecordLinks::Guard.reset!
  end

  describe "chores appearing on the list" do
    it "puts a chore that is due today on the list" do
      chore!("Water Plants", recurrence: { freq: :daily })

      described_class.push(user)

      expect(item_names).to include("Water Plants")
    end

    it "puts an overdue carryover on the list" do
      chore!("Vacuum", recurrence: { freq: :daily }, starts_on: day - 5)
      chore = Chore.find_by(name: "Vacuum")
      chore.update!(marked_due_at: ChoreDay.starts_at(day - 3, user) + 1.hour)

      described_class.push(user)

      expect(item_names).to include("Vacuum")
    end

    it "leaves off a chore that is on Today but not due" do
      chore!("Tidy Desk", show_on_today_view: :always)

      described_class.push(user)

      expect(item_names).not_to include("Tidy Desk")
    end

    it "leaves off a chore that has already been done today" do
      chore = chore!("Dishes", recurrence: { freq: :daily })
      ChoreCompleter.new(chore, user).call

      described_class.push(user)

      expect(item_names).not_to include("Dishes")
    end

    it "leaves off an occurrence that was skipped" do
      chore = chore!("Mop", recurrence: { freq: :daily })
      ChoreCompletion.create!(
        chore: chore, user: user, completed_at: Time.current, day_key: day,
        payout_skipped: true, anonymous: true, occurrence_skipped: true,
      )

      described_class.push(user)

      expect(item_names).not_to include("Mop")
    end

    it "takes the item off again once the chore is completed" do
      chore = chore!("Feed Cat", recurrence: { freq: :daily })
      described_class.push(user)
      expect(item_names).to include("Feed Cat")

      ChoreCompleter.new(chore, user).call
      described_class.push(user)

      expect(item_names).not_to include("Feed Cat")
    end

    it "leaves an item alone when it matches no chore at all" do
      type_item!("call the vet")

      described_class.push(user)

      expect(item_names).to include("call the vet")
    end
  end

  describe "ordering" do
    # "Most recently due chores appear at the top" — today's work first, the
    # thing that has been sitting for weeks at the bottom.
    it "sorts most-recently-due first" do
      chore!("Today Job", recurrence: { freq: :daily })
      old = chore!("Ancient Job", one_off: true, starts_on: day - 20)
      mid = chore!("Middling Job", one_off: true, starts_on: day - 2)
      expect([old, mid]).to all(be_persisted)

      described_class.push(user)

      expect(item_names.first(3)).to eq(["Today Job", "Middling Job", "Ancient Job"])
    end
  end

  describe "an item typed onto the list" do
    it "creates a one-off chore due today" do
      expect { type_item!("Wash the Car") }.to change(Chore, :count).by(1)

      chore = Chore.find_by(name: "Wash the Car")
      expect(chore.one_off).to be(true)
      expect(chore.starts_on).to eq(day)
      expect(ChoreSerializer.new(chore, viewer: user).as_json[:due_today]).to be(true)
    end

    it "marks an existing chore due instead of making a second one" do
      chore = chore!("Change Air Filter")

      expect { type_item!("change air filter") }.not_to change(Chore, :count)
      expect(chore.reload.marked_due_at).to be_present
    end

    it "does not react to an item on some other list" do
      other = List.create!(name: "Todo").tap { |l| UserList.create!(user: user, list: l, is_owner: true) }

      expect { other.list_items.add("Wash the Dog") }.not_to change(Chore, :count)
    end
  end

  describe "an item ticked off the list" do
    it "completes the chore it names" do
      chore = chore!("Take Out Trash", recurrence: { freq: :daily })
      described_class.push(user)

      expect { tick_item!("Take Out Trash") }.to change { chore.chore_completions.count }.by(1)
    end

    it "does nothing for an item that names no chore" do
      type_item!("call the vet")
      Chore.where(chore_household: household).delete_all

      expect { tick_item!("call the vet") }.not_to change(ChoreCompletion, :count)
    end

    # A stale item — the chore was finished somewhere else and the row is still
    # sitting on the list. Ticking it must not write a second completion.
    it "does not complete a chore that is already done today" do
      chore = chore!("Wipe Counters", recurrence: { freq: :daily })
      described_class.push(user)
      ChoreCompleter.new(chore, user).call
      list.list_items.add("Wipe Counters") # put the stale row back by hand

      expect { described_class.new(user).on_item("Wipe Counters", :removed) }
        .not_to change { chore.chore_completions.count }
    end
  end

  describe "not eating itself" do
    # The mirror removes the item BECAUSE the chore was completed. If that
    # removal were read as a tick, it would write a second completion.
    it "writes exactly one completion when a completion clears the item" do
      chore = chore!("Laundry", recurrence: { freq: :daily })
      described_class.push(user)
      expect(item_names).to include("Laundry")

      expect { ChoreCompleter.new(chore, user).call }.to change { chore.chore_completions.count }.by(1)
      expect(item_names).not_to include("Laundry")
    end

    # And the other way: the mirror ADDS the item because the chore is due. If
    # that add were read as "a person typed this", it would stamp marked_due on
    # a chore whose schedule already answered for it.
    it "does not stamp marked_due on a chore it placed itself" do
      chore = chore!("Sweep", recurrence: { freq: :daily })

      described_class.push(user)

      expect(item_names).to include("Sweep")
      expect(chore.reload.marked_due_at).to be_nil
    end
  end
end
