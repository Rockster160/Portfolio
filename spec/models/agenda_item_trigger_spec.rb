require "rails_helper"

RSpec.describe "AgendaItem Jil trigger reach" do
  # Who an agenda item's Jil trigger fires for, and what it tells them.
  #
  # `AgendaItem#user` is `agenda.user` — whoever OWNS the calendar, which is a
  # different question from whose day the event is on. So the trigger only ever
  # went to the owner, and a task could not see anything on a calendar shared IN
  # to it, however plainly the item was part of that person's day.
  #
  # Prod, Sat 8/15: "Games @ lucky ones" at 10:00 AM sat on agenda 2 — Chelsea's
  # calendar, shared to Rocco. It was on his dashboard, it was in his morning
  # briefing with its 34-minute drive, and the travel chain had worked out a
  # leave-by time for it from his address. His `Pre-Morning Event Fade` never ran,
  # because the trigger fired as her. The identical event on the jointly-owned
  # calendar the next morning worked perfectly, which is what made it look
  # intermittent rather than structural.
  describe "reach" do
    let(:owner)  { create(:user, username: "Alchemibluum") }
    let(:sharer) { create(:user, username: "Rockster160") }
    let(:agenda) { create(:agenda, user: owner) }

    # [user, serialized payload] for every :agenda_item trigger raised in the
    # block.
    #
    # SNAPSHOTTED at the moment of the call, on purpose. A Jil trigger's payload is
    # the AR record itself (`with_jil_attrs` stashes the extra attrs on it and
    # hands back `self`), so all the fires in one fan-out share one object and only
    # the last one's attrs survive the loop. That's fine where it matters —
    # Task#match_run runs `Jil::Executor.call` INLINE, so each viewer's tasks have
    # finished before the next viewer's attrs are written — but it means a test
    # holding the object and reading it afterwards is reading the wrong fire.
    def agenda_triggers
      calls = []
      allow(::Jil).to receive(:trigger) { |user, scope, payload|
        calls << [user, payload.serialize(use_global_id: false)] if scope == :agenda_item
      }
      yield
      calls
    end

    def create_item!
      create(
        :agenda_item, agenda: agenda, kind: "event",
        name: "Games @ lucky ones", start_at: 1.hour.from_now, end_at: 2.hours.from_now
      )
    end

    describe "a calendar shared in" do
      before { AgendaShare.create!(agenda: agenda, user: sharer) }

      it "reaches both the owner and the person it's shared with" do
        fired = agenda_triggers { create_item! }

        expect(fired.map(&:first)).to contain_exactly(owner, sharer)
      end

      it "reaches them on an update too" do
        item  = create_item!
        fired = agenda_triggers { item.update!(name: "Games, moved") }

        expect(fired.map(&:first)).to contain_exactly(owner, sharer)
      end

      # A task that schedules something off a partner's event needs the removal as
      # much as the addition, or it books the fade and never cancels it.
      it "reaches them on a destroy" do
        item  = create_item!
        fired = agenda_triggers { item.destroy! }

        expect(fired.map(&:first)).to contain_exactly(owner, sharer)
      end

      describe "what the payload says about whose it is" do
        # The payload a listener matches against is `serialize` — which merges the
        # execution attrs in — NOT `jil_serialize`, which never reaches matching.
        def payload_for(user)
          fired = agenda_triggers { create_item! }
          fired.find { |u, _| u == user }.last
        end

        it "tells the owner the calendar is theirs" do
          expect(payload_for(owner)[:mine]).to be(true)
        end

        it "tells the other person it isn't" do
          expect(payload_for(sharer)[:mine]).to be(false)
        end

        # So a task can skip one person's calendar without having to know the slug
        # of every calendar they might own now or later.
        it "names the owner on both copies" do
          expect(payload_for(sharer)[:owner]).to eq("Alchemibluum")
          expect(payload_for(owner)[:owner]).to eq("Alchemibluum")
          expect(payload_for(sharer)[:owner_id]).to eq(owner.id)
        end

        it "still carries the action" do
          expect(payload_for(sharer)[:action]).to eq(:created)
        end

        # The calendar was always identifiable; that shouldn't have changed.
        it "still carries the calendar it came off" do
          expect(payload_for(sharer)[:agenda_slug]).to eq(agenda.parameterized_name)
        end
      end

      # The whole point of putting it in the payload rather than deciding upstream.
      describe "filtering on it from a listener" do
        def matches?(listener, user)
          fired   = agenda_triggers { create_item! }
          payload = fired.find { |u, _| u == user }.last

          Jil::ListenerMatch.call(listener, "agenda_item", payload, serialized: payload)
        end

        it "can take only my own calendars" do
          expect(matches?("agenda_item:mine:true", owner)).to be(true)
          expect(matches?("agenda_item:mine:true", sharer)).to be(false)
        end

        it "can take only what's shared in" do
          expect(matches?("agenda_item:mine:false", sharer)).to be(true)
        end

        it "can single out one person's calendar" do
          expect(matches?("agenda_item:owner:Alchemibluum", sharer)).to be(true)
          expect(matches?("agenda_item:owner:Someone-Else", sharer)).to be(false)
        end

        # The six tasks live in prod carry no `mine`/`owner` filter, so they have
        # to keep matching everything — that's what "fire on all agendas I have
        # access to" means for them.
        it "leaves an unfiltered listener matching both" do
          expect(matches?("agenda_item:action:created", owner)).to be(true)
          expect(matches?("agenda_item:action:created", sharer)).to be(true)
        end
      end
    end

    describe "a calendar shared with nobody" do
      it "fires once, for the owner" do
        fired = agenda_triggers { create_item! }

        expect(fired.map(&:first)).to eq([owner])
      end
    end

    # A recurring thing on a partner's calendar is on the day exactly as much as a
    # one-off is, so the series had no business being the half that stayed
    # invisible. Same reach, same spelling — a listener shouldn't have to check
    # which scope it's on to know what `mine` means.
    describe "a recurring series" do
      before { AgendaShare.create!(agenda: agenda, user: sharer) }

      def schedule_triggers
        calls = []
        allow(::Jil).to receive(:trigger) { |user, scope, payload|
          calls << [user, payload.serialize(use_global_id: false)] if scope == :agenda_schedule
        }
        yield
        calls
      end

      def create_schedule!
        create(
          :agenda_schedule, agenda: agenda, kind: "event", duration_minutes: 60,
          name: "Yoga", start_time: "09:25", recurrence: { "freq" => "daily" }
        )
      end

      it "reaches both the owner and the person it's shared with" do
        fired = schedule_triggers { create_schedule! }

        expect(fired.map(&:first)).to contain_exactly(owner, sharer)
      end

      it "says whose calendar it is, in the same words an item does" do
        fired  = schedule_triggers { create_schedule! }
        theirs = fired.find { |u, _| u == sharer }.last

        expect(theirs[:mine]).to be(false)
        expect(theirs[:owner]).to eq("Alchemibluum")
        expect(theirs[:owner_id]).to eq(owner.id)
      end

      it "tells the owner it's theirs" do
        fired = schedule_triggers { create_schedule! }
        ours  = fired.find { |u, _| u == owner }.last

        expect(ours[:mine]).to be(true)
      end
    end

    # Suppressed mid-sync so a backfill doesn't storm; fanning out must not have
    # quietly turned that back on, times two.
    it "stays silent during a Google sync" do
      AgendaShare.create!(agenda: agenda, user: sharer)

      fired = agenda_triggers {
        Thread.current[::GoogleCalendar::Sync::SUPPRESS_KEY] = true
        begin
          create_item!
        ensure
          Thread.current[::GoogleCalendar::Sync::SUPPRESS_KEY] = nil
        end
      }

      expect(fired).to be_empty
    end
  end

  describe "kind" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }

    describe "kind enum" do
      it "includes :trigger" do
        expect(AgendaItem.kinds).to include("trigger" => 2)
        expect(AgendaSchedule.kinds).to include("trigger" => 2)
      end
    end

    describe "Execution.auth_types" do
      it "includes :agenda for items fired by agenda triggers" do
        expect(Execution.auth_types["agenda"]).to eq(10)
      end
    end

    describe "AgendaItem#parsed_trigger" do
      it "returns [scope, data] with agenda_item tieback for a bare expression" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Morning routine", trigger_expression: "goodMorning",
          start_at: 1.hour.from_now)
        scope, data = item.parsed_trigger
        expect(scope).to eq("goodMorning")
        expect(data[:agenda_item]).to include(id: item.id, agenda_id: agenda.id, name: "Morning routine")
      end

      it "parses nested scope:key:value into data" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Quiet alert", trigger_expression: "notify:tone:soft",
          start_at: 1.hour.from_now)
        scope, data = item.parsed_trigger
        expect(scope).to eq("notify")
        expect(data[:tone]).to eq("soft")
        expect(data[:agenda_item]).to be_present
      end

      it "supports quoted segments with spaces" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Spaced key", trigger_expression: 'alert:"my key":value',
          start_at: 1.hour.from_now)
        scope, data = item.parsed_trigger
        expect(scope).to eq("alert")
        expect(data[:"my key"]).to eq("value")
      end

      it "returns [nil, {}] for non-trigger kinds" do
        item = create(:agenda_item, agenda: agenda, kind: "task", name: "Walk dog",
          start_at: 1.hour.from_now)
        expect(item.parsed_trigger).to eq([nil, {}])
      end

      it "returns [nil, {}] for trigger items with blank trigger_expression" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Empty trigger", trigger_expression: nil,
          start_at: 1.hour.from_now)
        expect(item.parsed_trigger).to eq([nil, {}])
      end

      it "non-event triggers have nil end_at when generated from a schedule" do
        sched = create(:agenda_schedule, agenda: agenda, kind: "trigger",
          name: "Morning ping", trigger_expression: "ping",
          recurrence: { "freq" => "daily" }, starts_on: Date.current)
        # 7 days are auto-materialized for trigger schedules; query beyond the
        # window to exercise the phantom path.
        phantom = sched.phantom_for(Date.current + 30)
        expect(phantom.end_at).to be_nil
        expect(phantom.trigger_expression).to eq("ping")
      end
    end

    describe "AgendaSchedule#materialize_upcoming!" do
      it "materializes occurrences that fall inside the forward window" do
        sched = nil
        start_time = 1.hour.from_now.strftime("%H:%M")
        expect {
          sched = create(:agenda_schedule, agenda: agenda, kind: "trigger",
            name: "Morning ping", trigger_expression: "morning_ping",
            start_time: start_time,
            recurrence: { "freq" => "daily" }, starts_on: Date.current)
        }.to change { AgendaItem.where(kind: :trigger).count }.by_at_least(1)
        expect(sched.agenda_items.pluck(:trigger_expression).uniq).to eq(["morning_ping"])
      end

      it "does NOT pre-materialize occurrences whose first match is beyond the window" do
        # Push starts_on past the window so no matching date lands inside it.
        expect {
          create(:agenda_schedule, agenda: agenda, kind: "trigger",
            name: "Late ping", trigger_expression: "late_ping",
            start_time: "08:00",
            recurrence: { "freq" => "daily" }, starts_on: Date.current + 7)
        }.not_to change { AgendaItem.where(kind: :trigger).count }
      end

      # How MANY occurrences land depends on where `now` sits inside
      # MATERIALIZE_WINDOW, so these pin the SHAPE of each one instead. (The
      # earlier version derived start_time from `1.hour.from_now` in the Rails
      # zone and handed the bare "%H:%M" to a schedule that reads it as LOCAL
      # time, so it silently drifted by a day once UTC crossed midnight.)
      it "materializes event schedules forward with end_at derived from duration" do
        travel_to(Time.utc(2026, 5, 14, 18, 0)) {
          sched = create(:agenda_schedule, agenda: agenda, kind: "event",
            name: "Tech Stand-Up", duration_minutes: 30,
            start_time: "14:00",
            recurrence: { "freq" => "daily" }, starts_on: Date.current)

          items = sched.agenda_items.where(kind: :event).to_a
          expect(items).not_to be_empty
          items.each { |item|
            expect(item.end_at).to be_within(1.second).of(item.start_at + 30.minutes)
          }
        }
      end

      it "materializes task schedules forward with nil end_at" do
        travel_to(Time.utc(2026, 5, 14, 18, 0)) {
          sched = create(:agenda_schedule, agenda: agenda, kind: "task",
            name: "Stretch", start_time: "14:00",
            recurrence: { "freq" => "daily" }, starts_on: Date.current)

          items = sched.agenda_items.where(kind: :task).to_a
          expect(items).not_to be_empty
          expect(items.map(&:end_at)).to all(be_nil)
        }
      end

      it "leaves out-of-window event/task occurrences as phantoms" do
        expect {
          create(:agenda_schedule, agenda: agenda, kind: "event",
            name: "Far event", duration_minutes: 30,
            start_time: "08:00",
            recurrence: { "freq" => "daily" }, starts_on: Date.current + 7)
        }.not_to change(AgendaItem, :count)
      end
    end

    describe "FireDueAgendaTriggersWorker" do
      it "fires due trigger items and stamps fired_at WITHOUT touching completed_at" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Ping reminder", trigger_expression: "ping",
          start_at: 5.minutes.ago, completed_at: nil)
        expect(::Jil).to receive(:trigger).with(user, "ping", hash_including(agenda_item: include(id: item.id)),
          auth: :agenda, auth_id: item.id)
        FireDueAgendaTriggersWorker.new.perform
        expect(item.reload.fired_at).to be_present
        expect(item.completed_at).to be_nil
      end

      it "doesn't refire a trigger that already has fired_at set" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Ping", trigger_expression: "ping",
          start_at: 5.minutes.ago, fired_at: 4.minutes.ago)
        expect(::Jil).not_to receive(:trigger)
        FireDueAgendaTriggersWorker.new.perform
      end

      it "ignores triggers in the future" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Ping", trigger_expression: "ping",
          start_at: 1.hour.from_now, completed_at: nil)
        expect(::Jil).not_to receive(:trigger)
        FireDueAgendaTriggersWorker.new.perform
        expect(item.reload.completed_at).to be_nil
      end

      it "ignores already-completed triggers" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Ping", trigger_expression: "ping",
          start_at: 5.minutes.ago, completed_at: 1.minute.ago)
        expect(::Jil).not_to receive(:trigger)
        FireDueAgendaTriggersWorker.new.perform
      end

      it "routes `command:` triggers through Jarvis instead of Jil" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Wash Dishes Reminder",
          trigger_expression: 'command:"Remind me to wash dishes"',
          start_at: 5.minutes.ago, completed_at: nil)
        expect(::Jarvis).to receive(:command).with(user, "Remind me to wash dishes")
        expect(::Jil).not_to receive(:trigger)
        FireDueAgendaTriggersWorker.new.perform
        expect(item.reload.fired_at).to be_present
        expect(item.completed_at).to be_nil
      end

      it "handles `command:words` without quotes when there are no extra colons" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Reminder",
          trigger_expression: "command:Remind me to take out trash",
          start_at: 5.minutes.ago, completed_at: nil)
        expect(::Jarvis).to receive(:command).with(user, "Remind me to take out trash")
        FireDueAgendaTriggersWorker.new.perform
      end

      it "preserves nested quotes inside the command words" do
        item = create(:agenda_item, agenda: agenda, kind: "trigger",
          name: "Plants Reminder",
          trigger_expression: 'command:Remind me to "add water to plants"',
          start_at: 5.minutes.ago, completed_at: nil)
        expect(::Jarvis).to receive(:command).with(user, 'Remind me to "add water to plants"')
        FireDueAgendaTriggersWorker.new.perform
      end
    end
  end
end
