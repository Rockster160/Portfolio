require "rails_helper"

RSpec.describe "AgendaItem Jil trigger reach" do
  # Who an agenda item's Jil trigger fires for, and what it tells them.
  # `AgendaItem#user` is whoever OWNS the calendar, which is a different
  # question from whose day the event is on: a calendar shared IN is part of
  # the recipient's day too, so their tasks have to hear about it.
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

      it "reaches both the owner and the person it's shared with, on create, update and destroy" do
        item = nil
        created = agenda_triggers { item = create_item! }
        updated = agenda_triggers { item.update!(name: "Games, moved") }
        destroyed = agenda_triggers { item.destroy! }

        [created, updated, destroyed].each do |fired|
          expect(fired.map(&:first)).to contain_exactly(owner, sharer)
        end
      end

      # The payload a listener matches against is `serialize` — which merges the
      # execution attrs in — NOT `jil_serialize`, which never reaches matching.
      # Carrying `mine`/`owner` lets a task skip one person's calendar without
      # knowing the slug of every calendar they own.
      it "tells each recipient whose calendar it is, and a listener can filter on it", :aggregate_failures do
        fired = agenda_triggers { create_item! }
        ours = fired.find { |u, _| u == owner }.last
        theirs = fired.find { |u, _| u == sharer }.last

        expect(ours[:mine]).to be(true)
        expect(theirs[:mine]).to be(false)
        expect([ours[:owner], theirs[:owner]]).to all(eq("Alchemibluum"))
        expect(theirs[:owner_id]).to eq(owner.id)
        expect(theirs[:action]).to eq(:created)
        expect(theirs[:agenda_slug]).to eq(agenda.parameterized_name)

        matches = ->(listener, payload) {
          Jil::ListenerMatch.call(listener, "agenda_item", payload, serialized: payload)
        }
        expect(matches.call("agenda_item:mine:true", ours)).to be(true)
        expect(matches.call("agenda_item:mine:true", theirs)).to be(false)
        expect(matches.call("agenda_item:mine:false", theirs)).to be(true)
        expect(matches.call("agenda_item:owner:Alchemibluum", theirs)).to be(true)
        expect(matches.call("agenda_item:owner:Someone-Else", theirs)).to be(false)
        # An unfiltered listener keeps matching every agenda the person can see.
        expect(matches.call("agenda_item:action:created", ours)).to be(true)
        expect(matches.call("agenda_item:action:created", theirs)).to be(true)
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

      it "reaches both, saying whose calendar it is in the same words an item does" do
        fired  = schedule_triggers { create_schedule! }
        ours   = fired.find { |u, _| u == owner }.last
        theirs = fired.find { |u, _| u == sharer }.last

        expect(fired.map(&:first)).to contain_exactly(owner, sharer)
        expect(ours[:mine]).to be(true)
        expect(theirs[:mine]).to be(false)
        expect(theirs[:owner]).to eq("Alchemibluum")
        expect(theirs[:owner_id]).to eq(owner.id)
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

    describe "AgendaItem#parsed_trigger" do
      it "parses the expression into scope and data with an agenda_item tieback", :aggregate_failures do
        trigger = ->(name, expression) {
          create(:agenda_item, agenda: agenda, kind: "trigger",
            name: name, trigger_expression: expression, start_at: 1.hour.from_now)
        }

        item = trigger.call("Morning routine", "goodMorning")
        scope, data = item.parsed_trigger
        expect(scope).to eq("goodMorning")
        expect(data[:agenda_item]).to include(id: item.id, agenda_id: agenda.id, name: "Morning routine")

        scope, data = trigger.call("Quiet alert", "notify:tone:soft").parsed_trigger
        expect(scope).to eq("notify")
        expect(data[:tone]).to eq("soft")
        expect(data[:agenda_item]).to be_present

        scope, data = trigger.call("Spaced key", 'alert:"my key":value').parsed_trigger
        expect(scope).to eq("alert")
        expect(data[:"my key"]).to eq("value")

        expect(trigger.call("Empty trigger", nil).parsed_trigger).to eq([nil, {}])
        task = create(:agenda_item, agenda: agenda, kind: "task", name: "Walk dog", start_at: 1.hour.from_now)
        expect(task.parsed_trigger).to eq([nil, {}])
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

      it "skips one already fired, one still ahead, and one already completed" do
        [
          { start_at: 5.minutes.ago, fired_at: 4.minutes.ago },
          { start_at: 1.hour.from_now },
          { start_at: 5.minutes.ago, completed_at: 1.minute.ago },
        ].each do |attrs|
          create(:agenda_item, agenda: agenda, kind: "trigger", name: "Ping", trigger_expression: "ping", **attrs)
        end
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

      it "reads the command words unquoted, and keeps quotes nested inside them" do
        create(:agenda_item, agenda: agenda, kind: "trigger", name: "Reminder",
          trigger_expression: "command:Remind me to take out trash", start_at: 5.minutes.ago)
        create(:agenda_item, agenda: agenda, kind: "trigger", name: "Plants Reminder",
          trigger_expression: 'command:Remind me to "add water to plants"', start_at: 5.minutes.ago)
        expect(::Jarvis).to receive(:command).with(user, "Remind me to take out trash")
        expect(::Jarvis).to receive(:command).with(user, 'Remind me to "add water to plants"')
        FireDueAgendaTriggersWorker.new.perform
      end
    end
  end
end
