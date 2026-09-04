require "rails_helper"
require "timeout"

# The Rails replacement for Jil tasks 362, 365, 366, 370, 374, 383 and 416.
#
# These pairings run a real household, so the bar is not "works" — it's "does
# what the Jil version did", including the awkward parts: +/-1-second partner
# matching, a renamed event taking its completion with it, and every write being
# a no-op when the partner already agrees.
#
# Completing a chore no longer writes an ActionEvent (363) and never will — the
# cascade validation forbids it outright.
#
# Adding a list item marking a chore due (382) is gone as a GENERAL rule and
# available per pairing, through `reverse`. Both halves are pinned below: a
# plain link still refuses to run up, and a reverse one runs up and stops.
RSpec.describe RecordLinks::Propagator do
  let(:user)      { User.me }
  let(:household) { user.chore_household }

  def link!(source, source_name, target, target_name, **opts)
    RecordLink.create!({
      user:        user,
      source_kind: source,
      source_name: source_name,
      target_kind: target,
      target_name: target_name,
    }.merge(opts))
  end

  def chore!(name)
    Chore.create!(chore_household: household, created_by_user: user, name: name)
  end

  def list!(name)
    List.create!(name: name).tap { |l| UserList.create!(user: user, list: l, is_owner: true) }
  end

  # A real log through the real notifier, so the whole bus runs rather than the
  # propagator being poked directly.
  def log_event!(name, notes: nil, at: Time.current)
    event = user.action_events.create!(name: name, notes: notes, timestamp: at)
    ActionEventNotifier.notify(user, event, :added)
    event
  end

  def remove_event!(event)
    event.destroy!
    ActionEventNotifier.notify(user, event, :removed)
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    allow(ActionEventBroadcastWorker).to receive(:perform_async)
    allow(ChoreBroadcaster).to receive(:broadcast_changes!)
    RecordLink.delete_all
    user.action_events.delete_all
    ChoreCompletion.where(user_id: user.id).delete_all
    Chore.where(chore_household: household).delete_all
    RecordLinks::Guard.reset!
  end

  describe "the cascade only running downhill" do
    it "accepts event -> chore -> agenda -> list item, in that order" do
      expect(link!(:event, "A", :chore, "B")).to be_persisted
      expect(link!(:chore, "B", :agenda, "C")).to be_persisted
      expect(link!(:agenda, "C", :list_item, "D", target_scope: "Todo")).to be_persisted
      expect(link!(:event, "A", :list_item, "E", target_scope: "Todo")).to be_persisted
    end

    # These two were real rules and are the reason the old pair could chase each
    # other in a circle.
    it "refuses a chore writing an event" do
      bad = RecordLink.new(user: user, source_kind: :chore, source_name: "X", target_kind: :event, target_name: "Y")

      expect(bad).not_to be_valid
      expect(bad.errors[:target_kind].join).to include("event -> chore -> agenda -> list_item")
    end

    it "refuses a list item touching a chore" do
      bad = RecordLink.new(user: user, source_kind: :list_item, source_name: "X", target_kind: :chore, target_name: "Y")

      expect(bad).not_to be_valid
    end

    it "refuses a link to the same kind" do
      expect(RecordLink.new(
               user: user, source_kind: :chore, source_name: "X",
               target_kind: :chore, target_name: "Y"
      )).not_to be_valid
    end
  end

  describe "an event completing its chore" do
    let!(:chore) { chore!("Shower") }

    before { link!(:event, "Shower", :chore, "Shower") }

    it "creates the completion when the event is logged" do
      expect { log_event!("Shower") }.to change { chore.chore_completions.count }.by(1)
    end

    it "does nothing for an event that isn't linked" do
      expect { log_event!("Coffee") }.not_to change(ChoreCompletion, :count)
    end

    # The clock IS the join key — there's no foreign key between a completion
    # and its event — so an edit has to be handed the OLD time to find what to
    # move.
    it "moves the completion when the event's time is edited" do
      at = 2.hours.ago.change(usec: 0)
      event = log_event!("Shower", at: at)
      completion = chore.chore_completions.first

      moved = at - 1.hour
      event.update!(timestamp: moved)
      described_class.on_event(user, event, :changed, changes: { "timestamp" => [at, moved] })

      expect(completion.reload.completed_at).to be_within(1.second).of(moved)
      expect(chore.chore_completions.count).to eq(1)
    end

    it "destroys the completion when the event is renamed out of the link" do
      at = 1.hour.ago.change(usec: 0)
      event = log_event!("Shower", at: at)
      expect(chore.chore_completions.count).to eq(1)

      event.update!(name: "Bath")
      described_class.on_event(user, event, :changed, changes: { "name" => %w[Shower Bath] })

      expect(chore.chore_completions.count).to eq(0)
    end

    it "destroys the completion when the event is deleted" do
      event = log_event!("Shower", at: 1.hour.ago.change(usec: 0))
      expect { remove_event!(event) }.to change { chore.chore_completions.count }.by(-1)
    end

    # Idempotence is not an optimisation here; it's half the loop safety.
    it "does not make a second completion for a partner that already agrees" do
      event = log_event!("Shower", at: 1.hour.ago.change(usec: 0))

      3.times { described_class.on_event(user, event, :added) }

      expect(chore.chore_completions.count).to eq(1)
    end

    # The whole point of two independent endpoints.
    it "pairs ends with completely different names" do
      chore!("Focus")
      link!(:event, "D-Amphetamine", :chore, "Focus")

      log_event!("D-Amphetamine")

      expect(Chore.find_by(name: "Focus").chore_completions.count).to eq(1)
    end
  end

  describe "how forgiving the source match is" do
    let!(:chore) { chore!("Cymbalta") }

    # The pairing that was most fragile: it hung on the exact notes string
    # "Duloxetine Hydrochlride 20mg", typo included, so re-typing it any other
    # way missed in silence.
    it "matches a medication by drug name regardless of dosage or spelling" do
      link!(:event, "M", :chore, "Cymbalta", source_scope: "Duloxetine", source_scope_match: :contains)

      log_event!("M", notes: "Duloxetine Hydrochloride 40mg")

      expect(chore.chore_completions.count).to eq(1)
    end

    it "would have missed that same log on an exact match" do
      link!(:event, "M", :chore, "Cymbalta", source_scope: "Duloxetine Hydrochlride 20mg")

      log_event!("M", notes: "Duloxetine Hydrochloride 40mg")

      expect(chore.chore_completions.count).to eq(0)
    end

    it "matches a name prefix" do
      chore!("Focus")
      link!(:event, "D-Amphetamine", :chore, "Focus", source_name_match: :starts_with)

      log_event!("D-Amphetamine 20mg")

      expect(Chore.find_by(name: "Focus").chore_completions.count).to eq(1)
    end

    it "is exact by default, and case-insensitive" do
      link!(:event, "Cymbalta", :chore, "Cymbalta")

      log_event!("cymbalta")
      expect(chore.chore_completions.count).to eq(1)

      log_event!("Cymbalta extra", at: 2.hours.ago)
      expect(chore.chore_completions.count).to eq(1)
    end

    it "still requires the name when a scope is loose" do
      link!(:event, "M", :chore, "Cymbalta", source_scope: "Duloxetine", source_scope_match: :contains)

      log_event!("Vitamin", notes: "Duloxetine 20mg")

      expect(chore.chore_completions.count).to eq(0)
    end
  end

  describe "a notes constraint separating chores that share an event name" do
    let!(:litter) { chore!("Kitty Litter") }
    let!(:food)   { chore!("Refill Fae Food") }

    before do
      link!(:event, "Fae", :chore, "Kitty Litter", source_scope: "Litter")
      link!(:event, "Fae", :chore, "Refill Fae Food", source_scope: "Food")
    end

    it "completes only the chore whose notes match" do
      log_event!("Fae", notes: "Litter")

      expect(litter.chore_completions.count).to eq(1)
      expect(food.chore_completions.count).to eq(0)
    end

    it "completes neither when the notes match no link" do
      log_event!("Fae", notes: "Brushing")

      expect(ChoreCompletion.where(user_id: user.id).count).to eq(0)
    end
  end

  describe "a chore and its list item" do
    let!(:chore) { chore!("Pickup RX") }
    let!(:list)  { list!("Chores") }

    before { link!(:chore, "Pickup RX", :list_item, "Pickup RX", target_scope: "Chores") }

    it "puts the item on the list when the chore is marked due" do
      chore.update!(marked_due_at: Time.current)

      expect(list.reload.list_items.map(&:name)).to include("Pickup RX")
    end

    it "takes the item off when the chore is completed" do
      chore.update!(marked_due_at: Time.current)
      expect(list.reload.list_items.map(&:name)).to include("Pickup RX")

      ChoreCompleter.new(chore.reload, user, at: Time.current).call

      expect(list.reload.list_items.map(&:name)).not_to include("Pickup RX")
    end

    # Undoing a completion has to put the item back, or the person is left
    # walking it back by hand — which is the thing links exist to avoid.
    it "puts the item back when the completion is undone" do
      chore.update!(marked_due_at: Time.current)
      ChoreCompleter.new(chore.reload, user, at: Time.current).call
      completion = chore.chore_completions.first

      ChoreCompletionUndoer.call(user, completion)

      expect(list.reload.list_items.map(&:name)).to include("Pickup RX")
    end

    it "pairs a chore with a differently-named item" do
      chore!("Check Softener Salt")
      link!(:chore, "Check Softener Salt", :list_item, "Check Salt", target_scope: "Chores")

      Chore.find_by(name: "Check Softener Salt").update!(marked_due_at: Time.current)

      expect(list.reload.list_items.map(&:name)).to include("Check Salt")
    end

    # 382 is gone: the list is the bottom of the cascade and nothing runs up
    # from it.
    it "does NOT touch the chore when the item is added by hand" do
      list.list_items.add("Pickup RX")

      expect(chore.reload).not_to be_marked_due
    end
  end

  # The uphill escape hatch. `reverse` ADDS the backwards reading to a row
  # rather than replacing the forwards one — the uniqueness index covers the
  # two endpoints and not this column, so one pairing is one row either way.
  # "Pickup RX" wants both: the chore's item comes off the list when it's done,
  # and the chore comes due when the item goes back on.
  describe "a reverse pairing running uphill" do
    let!(:chore) { chore!("Pickup RX") }
    let!(:list)  { list!("Chores") }
    let!(:other) { list!("Todo") }

    before {
      link!(:chore, "Pickup RX", :list_item, "Pickup RX", target_scope: "Chores", reverse: true)
    }

    it "marks the chore due when the item is added to the list" do
      list.list_items.add("Pickup RX")

      expect(chore.reload).to be_marked_due
    end

    # The reason `Add Pickup RX to Chores` was reported broken: spoken adds go
    # through Jarvis, which reaches the model rather than either controller.
    it "marks it due for a model-path add, not just a controller one" do
      ListItem.create!(list: list, name: "Pickup RX").notify_jil(:added)

      expect(chore.reload).to be_marked_due
    end

    it "leaves the chore alone for the same words on a different list" do
      other.list_items.add("Pickup RX")

      expect(chore.reload).not_to be_marked_due
    end

    # Taking something off a list is as often a tidy-up as a claim it was done.
    it "does not unmark the chore when the item is removed" do
      chore.update!(marked_due_at: Time.current)

      list.list_items.remove("Pickup RX")

      expect(chore.reload).to be_marked_due
    end

    it "still carries the completion downhill off the same row" do
      list.list_items.add("Pickup RX")
      expect(chore.reload).to be_marked_due

      ChoreCompleter.new(chore.reload, user, at: Time.current).call

      expect(list.reload.list_items.map(&:name)).not_to include("Pickup RX")
    end

    # item -> chore -> item revisits the item endpoint and stops there. A
    # runaway would be dozens of triggers, or no return at all.
    it "terminates, adding the item exactly once" do
      item_triggers = 0
      allow(::Jil).to receive(:trigger).and_wrap_original { |orig, *args, **kw|
        item_triggers += 1 if args[1].to_sym == :item
        orig.call(*args, **kw)
      }

      Timeout.timeout(20) { list.list_items.add("Pickup RX") }

      expect(chore.reload).to be_marked_due
      expect(list.reload.list_items.where(name: "Pickup RX").count).to eq(1)
      expect(item_triggers).to be_between(1, 4)
    end

    # The other way in: marking the chore due pushes the item down, and the
    # item must not bounce a second stamp back up.
    it "does not re-stamp a chore that is already due" do
      chore.update!(marked_due_at: 2.hours.ago)
      was = chore.reload.marked_due_at

      Timeout.timeout(20) { list.list_items.add("Pickup RX") }

      expect(chore.reload.marked_due_at).to be_within(1.second).of(was)
    end

    it "says both directions in the manager" do
      reversed = RecordLink.find_by(reverse: true)

      expect(reversed.summary).to eq("chore:Pickup RX ↔ list_item:Pickup RX (Chores)")
      expect(reversed.sentence).to include("chore where name is exactly \"Pickup RX\" takes off the list list item \"Pickup RX\" on Chores")
      expect(reversed.sentence).to include("and back: list item where name is exactly \"Pickup RX\" and list is exactly \"Chores\" marks due chore \"Pickup RX\"")
    end
  end

  # A completion recorded for somebody else still has to run the RECORDER's
  # links. Prod, 04 Sep: "Pickup RX" credited to a housemate fired the trigger
  # at her, she owns no links, and the item sat on the Chores list.
  describe "a chore marked done on somebody else's behalf" do
    let(:housemate) { create(:user, chore_household: household) }
    let!(:chore)    { chore!("Pickup RX") }
    let!(:list)     { list!("Chores") }

    before {
      link!(:chore, "Pickup RX", :list_item, "Pickup RX", target_scope: "Chores")
      chore.update!(sharing_mode: :personal, marked_due_at: Time.current)
      expect(list.reload.list_items.map(&:name)).to include("Pickup RX")
    }

    it "takes the item off the list" do
      ChoreCompleter.new(chore.reload, housemate, at: Time.current, recorded_by: user).call

      expect(list.reload.list_items.map(&:name)).not_to include("Pickup RX")
    end

    it "leaves the item alone when nobody records it for them" do
      ChoreCompleter.new(chore.reload, housemate, at: Time.current).call

      expect(list.reload.list_items.map(&:name)).to include("Pickup RX")
    end
  end

  describe "a chore and its agenda task" do
    let!(:agenda) { Agenda.create!(user: user, name: "Mine") }
    let!(:chore)  { chore!("Shower") }

    before { link!(:chore, "Shower", :agenda, "Shower") }

    def agenda_item!(name, at:, completed: nil)
      agenda.agenda_items.create!(name: name, start_at: at, kind: :task, completed_at: completed)
    end

    it "ticks off today's matching task when the chore is completed" do
      item = agenda_item!("Shower", at: Time.current.change(hour: 9))

      ChoreCompleter.new(chore, user, at: Time.current).call

      expect(item.reload.completed_at).to be_present
    end

    it "un-ticks it when the completion is undone" do
      item = agenda_item!("Shower", at: Time.current.change(hour: 9))
      ChoreCompleter.new(chore, user, at: Time.current).call
      expect(item.reload.completed_at).to be_present

      ChoreCompletionUndoer.call(user, chore.chore_completions.first)

      expect(item.reload.completed_at).to be_nil
    end
  end

  describe "an event reaching the agenda directly (was tasks 370 and 374)" do
    let!(:agenda) { Agenda.create!(user: user, name: "Mine") }

    before { link!(:event, "D-Amphetamine", :agenda, "Focus") }

    def agenda_item!(name, at:)
      agenda.agenda_items.create!(name: name, start_at: at, kind: :task)
    end

    it "ticks off today's matching item, skipping the chore rung entirely" do
      item = agenda_item!("Focus", at: Time.current.change(hour: 9))

      log_event!("D-Amphetamine")

      expect(item.reload.completed_at).to be_present
    end

    it "leaves an item with a different name alone" do
      item = agenda_item!("Something else", at: Time.current.change(hour: 9))

      log_event!("D-Amphetamine")

      expect(item.reload.completed_at).to be_nil
    end

    it "reaches a renamed formulation when the link matches loosely" do
      RecordLink.find_by(source_name: "D-Amphetamine").update!(source_name_match: :starts_with)
      item = agenda_item!("Focus", at: Time.current.change(hour: 9))

      log_event!("D-AmphetamineXR")

      expect(item.reload.completed_at).to be_present
    end

    it "leaves a matching item on another day alone" do
      item = agenda_item!("Focus", at: 3.days.from_now.change(hour: 9))

      log_event!("D-Amphetamine")

      expect(item.reload.completed_at).to be_nil
    end

    # `overdue` reproduces task 370, which swept overdue Shower items too.
    it "reaches back for overdue items when the link says so" do
      link!(:event, "Shower", :agenda, "Shower", target_scope: "overdue")
      item = agenda_item!("Shower", at: 3.days.ago.change(hour: 9))

      log_event!("Shower")

      expect(item.reload.completed_at).to be_present
    end
  end

  describe "a full cascade" do
    let!(:chore)  { chore!("Shower") }
    let!(:list)   { list!("Chores") }
    let!(:agenda) { Agenda.create!(user: user, name: "Mine") }

    it "runs event -> chore -> agenda and list item in one go" do
      link!(:event, "Shower", :chore, "Shower")
      link!(:chore, "Shower", :agenda, "Shower")
      link!(:chore, "Shower", :list_item, "Shower", target_scope: "Chores")
      chore.update!(marked_due_at: Time.current)
      task = agenda.agenda_items.create!(name: "Shower", start_at: Time.current.change(hour: 9), kind: :task)
      expect(list.reload.list_items.map(&:name)).to include("Shower")

      Timeout.timeout(10) { log_event!("Shower") }

      expect(chore.reload.chore_completions.count).to eq(1)
      expect(task.reload.completed_at).to be_present
      expect(list.reload.list_items.map(&:name)).not_to include("Shower")
    end

    # Downhill-only means there is no cycle to break, but the guard still has to
    # hold: a chore marked due adds an item, and nothing comes back up from it.
    it "terminates rather than circling" do
      link!(:chore, "Pickup RX", :list_item, "Pickup RX", target_scope: "Chores")
      chore!("Pickup RX")

      Timeout.timeout(10) { Chore.find_by(name: "Pickup RX").update!(marked_due_at: Time.current) }

      expect(list.reload.list_items.where(name: "Pickup RX").count).to eq(1)
    end

    it "survives a chore being re-marked due over and over" do
      link!(:chore, "Pickup RX", :list_item, "Pickup RX", target_scope: "Chores")
      c = chore!("Pickup RX")

      3.times { c.update!(marked_due_at: Time.current) }

      expect(list.reload.list_items.where(name: "Pickup RX").count).to eq(1)
    end
  end

  describe "ask_who" do
    let!(:chore) { chore!("Puppy Down") }
    let!(:partner) {
      create(:user).tap { |u|
        ChoreHouseholdMembership.create!(chore_household: household, user: u)
      }
    }

    # Three links into ONE chore, as in prod (record_links 21-23): the button
    # says `Nap`, `Sleep` or `Down` and all three mean the puppy went down.
    # Which one it came through is what separates a correction from a repeat.
    before do
      Prompt.where(user_id: user.id).delete_all
      link!(:event, "Whisper", :chore, "Puppy Down", source_scope: "Down", ask_who: true)
      link!(:event, "Whisper", :chore, "Puppy Down", source_scope: "Nap", ask_who: true)
      link!(:event, "Whisper", :chore, "Puppy Down", source_scope: "Sleep", ask_who: true)
    end

    def answer!(prompt, who, at)
      RecordLinks::Guard.reset!
      prompt.update!(response: { "Who did it?" => who, "When?" => at.iso8601 })
      Jil::Executor.trigger(user, :prompt, prompt.with_jil_attrs(status: :complete))
    end

    it "raises a prompt instead of completing anything" do
      expect { log_event!("Whisper", notes: "Down") }.to change { user.prompts.count }.by(1)
      expect(chore.chore_completions.count).to eq(0)
      expect(user.prompts.last.question).to eq("Who did: Puppy Down?")
    end

    it "asks once per event, not once per delivery" do
      event = log_event!("Whisper", notes: "Down")
      RecordLinks::Guard.reset!
      described_class.on_event(user, event, :added)

      expect(user.prompts.count).to eq(1)
    end

    # Prod, 26 Aug 22:00: two Whisper events nineteen seconds apart, 51790 and
    # 51791, put up two identical `Who did: Puppy Down?` forms. It was one press
    # for a nap corrected by a hold for sleep - the intended way to fix it - and
    # the device sends the same nameless event either way, so nothing downstream
    # can tell a correction from a second bedtime. He skipped one and answered
    # the other.
    describe "a second event while the first question is still open" do
      it "does not ask again when a nap is upgraded to sleep" do
        log_event!("Whisper", notes: "Nap")
        RecordLinks::Guard.reset!

        expect { log_event!("Whisper", notes: "Sleep") }.not_to(change { user.prompts.count })
      end

      # The correction goes the other way just as often - a hold read as sleep
      # when it was only a nap.
      it "does not ask again when sleep is corrected to a nap" do
        log_event!("Whisper", notes: "Sleep")
        RecordLinks::Guard.reset!

        expect { log_event!("Whisper", notes: "Nap") }.not_to(change { user.prompts.count })
      end

      # THE POINT OF THE SCOPE CHECK. There can be more than one nap in an
      # afternoon, and a second one is a second doing no matter how soon it
      # lands. Debouncing on the chore alone silently ate it.
      it "asks again for a second nap however close together" do
        log_event!("Whisper", notes: "Nap")
        RecordLinks::Guard.reset!

        expect { log_event!("Whisper", notes: "Nap") }.to change { user.prompts.count }.by(1)
      end

      # Answering either one writes the same completion, so nothing is lost by
      # only asking once.
      it "still writes the completion off the question it did ask" do
        log_event!("Whisper", notes: "Nap")
        RecordLinks::Guard.reset!
        log_event!("Whisper", notes: "Sleep")
        answer!(user.prompts.last, user.username, 1.hour.ago.change(usec: 0))

        expect(chore.reload.chore_completions.count).to eq(1)
      end

      it "asks again once the open one has been answered" do
        log_event!("Whisper", notes: "Nap")
        answer!(user.prompts.last, user.username, 1.hour.ago.change(usec: 0))

        expect { log_event!("Whisper", notes: "Sleep") }.to change { user.prompts.count }.by(1)
      end

      # A question left sitting unanswered must not swallow tomorrow's - and
      # since the window is measured between the EVENTS, this is also the case
      # where two genuinely distant doings arrive in the same instant. Both
      # prompts get made now; only the event times say they are separate.
      it "asks again for a doing well after the window" do
        log_event!("Whisper", notes: "Nap", at: 3.hours.ago)
        RecordLinks::Guard.reset!

        expect { log_event!("Whisper", notes: "Sleep") }.to change { user.prompts.count }.by(1)
      end

      # Prod, 31 Aug 22:00: events 51933 and 51934 fifty seconds apart, but the
      # second did not reach the database until 22:21:52 - so the prompts were
      # 21m42s apart and a guard measuring prompt time asked twice about one
      # bedtime. The events are what have to be close together.
      #
      # The backdated `created_at` IS the delivery gap: it puts the open prompt
      # outside a 15-minute window on prompt time while its event stays a
      # minute away from the one arriving now.
      it "does not ask twice when the second event arrives late" do
        log_event!("Whisper", notes: "Nap", at: 22.minutes.ago)
        user.prompts.last.update!(created_at: 22.minutes.ago)
        RecordLinks::Guard.reset!

        expect {
          log_event!("Whisper", notes: "Sleep", at: 21.minutes.ago)
        }.not_to(change { user.prompts.count })
      end

      # The open prompt's event is gone - prod destroyed 51934 - so there is no
      # timestamp to compare and it falls back to when the prompt was made. The
      # scope survives on the prompt, which is why it is stored there.
      it "still suppresses when the earlier event has been deleted" do
        event = log_event!("Whisper", notes: "Nap")
        RecordLinks::Guard.reset!
        event.destroy!

        expect { log_event!("Whisper", notes: "Sleep") }.not_to(change { user.prompts.count })
      end

      # Nothing to compare on, so it asks. Silence about a real second doing is
      # the worse of the two mistakes.
      it "asks again when the open question predates the stored scope" do
        log_event!("Whisper", notes: "Nap")
        prompt = user.prompts.last
        prompt.update!(params: prompt.params.to_h.except("scope", :scope))
        user.action_events.find(prompt.params["event_id"]).destroy!
        RecordLinks::Guard.reset!

        expect { log_event!("Whisper", notes: "Sleep") }.to change { user.prompts.count }.by(1)
      end

      it "leaves a question about a DIFFERENT chore alone" do
        chore!("Puppy Up")
        link!(:event, "Whisper", :chore, "Puppy Up", source_scope: "Up", ask_who: true)
        log_event!("Whisper", notes: "Down")
        RecordLinks::Guard.reset!

        expect { log_event!("Whisper", notes: "Up") }.to change { user.prompts.count }.by(1)
      end
    end

    # `datetime-local` renders an EMPTY box for a value it can't read, and an
    # offset on the end is enough to make it unreadable. The question arrives
    # with the time already rubbed off it, which is worse than not defaulting.
    it "defaults When to the event's local time, in the format the input reads" do
      at = Time.utc(2026, 8, 6, 19, 44)
      log_event!("Whisper", notes: "Down", at: at)

      when_field = user.prompts.last.options.find { |o| o["question"] == "When?" }
      expect(when_field["default"]).to eq(at.in_time_zone(user.timezone).strftime("%Y-%m-%dT%H:%M"))
      expect(when_field["default"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/)
    end

    it "completes for whoever was named when the answer comes back" do
      log_event!("Whisper", notes: "Down")
      prompt = user.prompts.last
      at = 1.hour.ago.change(usec: 0)

      prompt.update!(response: { "Who did it?" => user.username, "When?" => at.iso8601 })
      Jil::Executor.trigger(user, :prompt, prompt.with_jil_attrs(status: :complete))

      expect(chore.reload.chore_completions.count).to eq(1)
    end

    it "credits a household member who isn't the person the links belong to" do
      log_event!("Whisper", notes: "Down")
      at = 1.hour.ago.change(usec: 0)

      answer!(user.prompts.last, partner.username, at)

      expect(chore.reload.chore_completions.count).to eq(1)
      expect(chore.chore_completions.first.user_id).to eq(partner.id)
    end

    # One answer, one puppy, one payout — however many times the bus says so.
    # The row it has to notice is credited to whoever was NAMED, which is why
    # this can't go through the user-scoped `completion_partner`.
    it "logs once when the same answer is delivered twice" do
      log_event!("Whisper", notes: "Down")
      prompt = user.prompts.last
      at = 1.hour.ago.change(usec: 0)

      answer!(prompt, partner.username, at)
      answer!(prompt, partner.username, at)

      expect(chore.reload.chore_completions.count).to eq(1)
    end

    # Under Jil this branch DESTROYED the event, to undo a completion 362 had
    # already made from the same log. One row per pairing means there's nothing
    # to undo.
    it "keeps the event and stamps it with the answered time" do
      event = log_event!("Whisper", notes: "Down")
      prompt = user.prompts.last
      at = 3.hours.ago.change(usec: 0)

      prompt.update!(response: { "Who did it?" => user.username, "When?" => at.iso8601 })
      Jil::Executor.trigger(user, :prompt, prompt.with_jil_attrs(status: :complete))

      expect(ActionEvent.find_by(id: event.id)).to be_present
      expect(event.reload.timestamp).to be_within(1.second).of(at)
    end
  end

  describe "scoping and resilience" do
    it "does not run another person's links" do
      other = create(:user)
      RecordLink.create!(
        user: other, source_kind: :event, source_name: "Shower",
        target_kind: :chore, target_name: "Shower"
      )
      chore!("Shower")

      expect { log_event!("Shower") }.not_to change(ChoreCompletion, :count)
    end

    it "skips a disabled link" do
      chore!("Shower")
      link!(:event, "Shower", :chore, "Shower").update!(enabled: false)

      expect { log_event!("Shower") }.not_to change(ChoreCompletion, :count)
    end

    it "does not take down the trigger that fired it" do
      chore!("Shower")
      link!(:event, "Shower", :chore, "Shower")
      allow(ChoreCompleter).to receive(:new).and_raise("boom")

      expect { log_event!("Shower") }.not_to raise_error
      expect(user.action_events.where(name: "Shower")).to exist
    end

    it "shrugs off a link pointing at a chore that no longer exists" do
      link!(:event, "Ghost", :chore, "Deleted Chore")

      expect { log_event!("Ghost") }.not_to raise_error
    end

    it "shrugs off a link pointing at a list that no longer exists" do
      c = chore!("Pickup RX")
      link!(:chore, "Pickup RX", :list_item, "Pickup RX", target_scope: "Gone")

      expect { c.update!(marked_due_at: Time.current) }.not_to raise_error
    end
  end

  describe "an end pointing at nothing" do
    # Not an error anywhere — the link simply never fires — which is why the
    # manager has to ask and say so out loud.
    it "reports a chore that doesn't exist" do
      link = link!(:event, "Ghost", :chore, "Nonexistent Chore")

      expect(link.broken_ends).to include(/no chore called/)
    end

    it "reports a list that doesn't exist" do
      chore!("Real Chore")
      link = link!(:chore, "Real Chore", :list_item, "Thing", target_scope: "No Such List")

      expect(link.broken_ends).to include(/no list called/)
    end

    it "is quiet when both ends resolve" do
      chore!("Real Chore")
      list!("Chores")
      link = link!(:chore, "Real Chore", :list_item, "Thing", target_scope: "Chores")

      expect(link.broken_ends).to be_empty
    end
  end

  describe "the seeded pairings" do
    before { RecordLinks::Seed.plant!(user) }

    it "carries every downhill pairing from the Jil maps" do
      expect(RecordLink.where(user: user).count).to eq(44)
    end

    it "carries no uphill ones" do
      expect(RecordLink.where(user: user).all? { |l|
        RecordLink::RANK[l.source_kind.to_sym] < RecordLink::RANK[l.target_kind.to_sym]
      }).to be(true)
      expect(RecordLink.where(user: user, source_kind: :list_item)).to be_empty
      expect(RecordLink.where(user: user, target_kind: :event)).to be_empty
    end

    it "loosens the two pairings that were fragile" do
      cymbalta = RecordLink.find_by(user: user, source_name: "M")
      expect(cymbalta.source_scope).to eq("Duloxetine")
      expect(cymbalta.source_scope_match).to eq("contains")

      focus = RecordLink.where(user: user, source_name: "D-Amphetamine")
      expect(focus.pluck(:target_kind, :source_name_match)).to match_array([
        %w[chore starts_with], %w[agenda starts_with]
      ])
    end

    it "marks the ambiguous pairs ask_who" do
      link = RecordLink.find_by(user: user, source_name: "Fae", source_scope: "Litter")

      expect(link).to be_ask_who
      expect(link.target_name).to eq("Kitty Litter")
    end

    it "is idempotent" do
      expect { RecordLinks::Seed.plant!(user) }.not_to change(RecordLink, :count)
    end
  end
end
