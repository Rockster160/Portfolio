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
      chore!("Water Plants", one_off: true, starts_on: day)

      described_class.push(user)

      expect(item_names).to include("Water Plants")
    end

    it "puts an overdue carryover on the list" do
      chore!("Vacuum")
      chore = Chore.find_by(name: "Vacuum")
      chore.update!(marked_due_at: ChoreDay.starts_at(day - 3, user) + 1.hour)

      described_class.push(user)

      expect(item_names).to include("Vacuum")
    end

    # Almost every Dailies pin is `freq: daily`, so it IS due today every day.
    # The pin still wins — the list is what needs doing, not a copy of Today.
    it "leaves off a daily chore the viewer has pinned to Dailies" do
      chore = chore!("8oz Water", recurrence: { freq: :daily })
      ChoreDaily.create!(user: user, chore: chore)

      described_class.push(user)

      expect(item_names).not_to include("8oz Water")
    end

    # The recurrence says the same thing the pin does. A chore that comes round
    # every single day is a standing routine, pinned or not.
    it "leaves off a daily-recurring chore that is not pinned" do
      chore!("Kitty Litter", recurrence: { freq: :daily })

      described_class.push(user)

      expect(item_names).not_to include("Kitty Litter")
    end

    it "leaves off a chore that is on Today but not due" do
      chore!("Tidy Desk", show_on_today_view: :always)

      described_class.push(user)

      expect(item_names).not_to include("Tidy Desk")
    end

    it "leaves off a chore that has already been done today" do
      chore = chore!("Dishes", one_off: true, starts_on: day)
      ChoreCompleter.new(chore, user).call

      described_class.push(user)

      expect(item_names).not_to include("Dishes")
    end

    it "leaves off an occurrence that was skipped" do
      chore = chore!("Mop", one_off: true, starts_on: day)
      ChoreCompletion.create!(
        chore: chore, user: user, completed_at: Time.current, day_key: day,
        payout_skipped: true, anonymous: true, occurrence_skipped: true,
      )

      described_class.push(user)

      expect(item_names).not_to include("Mop")
    end

    it "takes the item off again once the chore is completed" do
      chore = chore!("Feed Cat", one_off: true, starts_on: day)
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
      chore!("Today Job", one_off: true, starts_on: day)
      old = chore!("Ancient Job", one_off: true, starts_on: day - 20)
      mid = chore!("Middling Job", one_off: true, starts_on: day - 2)
      expect([old, mid]).to all(be_persisted)

      described_class.push(user)

      expect(item_names.first(3)).to eq(["Today Job", "Middling Job", "Ancient Job"])
    end
  end

  describe "sections" do
    def section_layout
      list.reload.sectioned_objects.map { |obj|
        next [:loose, obj[:object].name] if obj[:type] == :item

        [obj[:object].name, obj[:items].map(&:name)]
      }
    end

    it "files each item under Today or Overdue" do
      chore!("Fresh Job", one_off: true, starts_on: day)
      chore!("Stale Job", one_off: true, starts_on: day - 4)

      described_class.push(user)

      expect(section_layout).to eq([
        ["Today", ["Fresh Job"]],
        ["Overdue", ["Stale Job"]],
      ])
    end

    # A row predating the mirror, or one whose chore has since gone. Typing onto
    # the list normally MAKES a chore, so `writing` is how you get a row here
    # that the mirror doesn't own.
    it "puts Today above Overdue, and anything it doesn't own below both" do
      chore!("Fresh Job", one_off: true, starts_on: day)
      chore!("Stale Job", one_off: true, starts_on: day - 4)
      described_class.writing { list.list_items.add("call the vet") }

      described_class.push(user)

      expect(section_layout).to eq([
        ["Today", ["Fresh Job"]],
        ["Overdue", ["Stale Job"]],
        [:loose, "call the vet"],
      ])
    end

    # A header for a state the list has never been in is noise.
    it "does not create a section it has never had an item for" do
      chore!("Stale Job", one_off: true, starts_on: day - 4)

      described_class.push(user)

      expect(section_layout).to eq([["Overdue", ["Stale Job"]]])
      expect(list.reload.sections.where_soft_name("Today")).to be_empty
    end

    # Once it exists it stays, empty or not — tearing it down and rebuilding it
    # would hand every item under it a new section id every morning.
    it "keeps an existing section in place when it empties out" do
      chore = chore!("Drifter", one_off: true, starts_on: day)
      stale = chore!("Stale Job", one_off: true, starts_on: day - 4)
      described_class.push(user)
      expect(section_layout).to eq([["Today", ["Drifter"]], ["Overdue", ["Stale Job"]]])

      ChoreCompleter.new(chore, user).call
      described_class.push(user)

      expect(section_layout).to eq([["Today", []], ["Overdue", ["Stale Job"]]])
      expect(stale).to be_persisted
      expect(list.reload.sections.count).to eq(2)
    end

    it "moves an item between sections without making a second section" do
      chore = chore!("Drifter", one_off: true, starts_on: day)
      described_class.push(user)
      expect(section_layout).to eq([["Today", ["Drifter"]]])

      chore.update!(starts_on: day - 3)
      described_class.push(user)

      expect(section_layout).to eq([["Today", []], ["Overdue", ["Drifter"]]])
      expect(list.reload.sections.where_soft_name("Overdue").count).to eq(1)
    end

    # Renumbering the whole list every pass is what keeps `sort_order` from
    # walking upward by the size of the list forever.
    it "does not inflate sort_order on a repeat reconcile" do
      chore!("Fresh Job", one_off: true, starts_on: day)
      chore!("Stale Job", one_off: true, starts_on: day - 4)

      described_class.push(user)
      first = list.reload.list_items.ordered.map(&:sort_order)
      3.times { described_class.push(user) }

      expect(list.reload.list_items.ordered.map(&:sort_order)).to eq(first)
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

    # Prod 16 Sep. "Unpack Dishes" is an alias of chore 78 "Unload Dishwasher",
    # so the uphill half resolved it and marked the chore due — and then the
    # mirror added a row under the chore's real name and left the typed one
    # sitting at the bottom, because `known_chore?` read names and not aliases.
    # Two rows for one chore, only one of which meant anything.
    it "replaces an item typed under a chore's alias with the chore's own name" do
      chore = chore!("Unload Dishwasher", aliases: ["unpack dishes"])

      expect { type_item!("Unpack Dishes") }.not_to change(Chore, :count)

      expect(chore.reload.marked_due_at).to be_present
      expect(item_names).to eq(["Unload Dishwasher"])
    end
  end

  # Marking a chore due asks for two syncs — `item_added` wants one and Chore's
  # own `after_commit` wants another — and Sidekiq runs them side by side. Both
  # read the list before either writes, so both add the same missing item.
  describe "two syncs racing" do
    # Across Sidekiq threads and processes, so the thread-local `writing` flag
    # can't see it and a spec can't stage it. What is worth pinning is that the
    # reconcile is behind a lock at all, and that the lock is per person — a
    # global one would make everyone's list wait on everyone else's.
    it "does the reconcile behind a lock of its own" do
      chore!("Unload Dishwasher", one_off: true, starts_on: day)
      expect(User).to receive(:with_advisory_lock).with("chore_list_sync_#{user.id}", 15.seconds).and_yield

      described_class.push(user)

      expect(item_names).to eq(["Unload Dishwasher"])
    end

    # What the race left behind, and what any earlier one left behind too: the
    # keeper was placed under Today and the twin kept the `max_sort_order + 1`
    # it was created with, which sorts ABOVE the Today header. A copy of the
    # chore pinned to the top of the list, in no section at all.
    it "clears a duplicate row rather than stranding it above every section" do
      chore!("Unload Dishwasher", one_off: true, starts_on: day)
      described_class.push(user)
      described_class.writing {
        list.list_items.create!(name: "Unload Dishwasher", sort_order: 1632)
      }

      described_class.push(user)

      expect(item_names).to eq(["Unload Dishwasher"])
      expect(list.reload.list_items.first.section.name).to eq("Today")
    end
  end

  describe "an item ticked off the list" do
    it "completes the chore it names" do
      chore = chore!("Take Out Trash", one_off: true, starts_on: day)
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
      chore = chore!("Wipe Counters", one_off: true, starts_on: day)
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
      chore = chore!("Laundry", one_off: true, starts_on: day)
      described_class.push(user)
      expect(item_names).to include("Laundry")

      expect { ChoreCompleter.new(chore, user).call }.to change { chore.chore_completions.count }.by(1)
      expect(item_names).not_to include("Laundry")
    end

    # And the other way: the mirror ADDS the item because the chore is due. If
    # that add were read as "a person typed this", it would stamp marked_due on
    # a chore whose schedule already answered for it.
    it "does not stamp marked_due on a chore it placed itself" do
      chore = chore!("Sweep", one_off: true, starts_on: day)

      described_class.push(user)

      expect(item_names).to include("Sweep")
      expect(chore.reload.marked_due_at).to be_nil
    end
  end
end
