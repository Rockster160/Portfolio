require "rails_helper"

RSpec.describe "Buddy agenda tools" do
  # Buddy putting things on, and moving things between, calendars.
  #
  # Built around prod 1201: "move it to the Ours agenda" produced an ADD, so the
  # same Costco Run ended up on two calendars at 1:00 PM. edit_agenda_item had no
  # way to name a calendar, so there was no correct call available.
  describe "the tools" do
    let(:user) { create(:user) }
    # User#ensure_default_agenda makes this one on save, so it is genuinely the
    # oldest — which is exactly the situation the default-calendar setting exists
    # to override, since a personal calendar always predates a shared one.
    let(:personal)  { user.agendas.order(:id).first }
    let!(:ours)     { create(:agenda, user: user, name: "Ours 💕") }
    let(:at)        { Time.current.tomorrow.change(hour: 13) }

    before {
      allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
    }

    def ctx
      Buddy::ToolContext.new(user)
    end

    def run(tool_name, payload)
      tool    = Buddy::Tools[tool_name]
      confirm = tool[:confirm].call(payload, ctx)
      [tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx), confirm]
    end

    def costco_on(agenda)
      agenda.agenda_items.create!(name: "Costco Run", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed)
    end

    describe "edit_agenda_item moving between calendars" do
      it "moves the existing item instead of leaving a second one behind" do
        item = costco_on(personal)

        run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours" })

        expect(item.reload.agenda_id).to eq(ours.id)
        expect(AgendaItem.where(name: "Costco Run").count).to eq(1)
      end

      it "puts it back on undo" do
        item = costco_on(personal)
        result, = run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours" })

        expect(item.reload.agenda_id).to eq(ours.id)
        Buddy::Reverter.call(result[:revert])

        expect(item.reload.agenda_id).to eq(personal.id)
      end

      it "refuses a calendar name that matches nothing rather than picking one" do
        costco_on(personal)

        expect {
          run(:edit_agenda_item, { item: "Costco Run", calendar: "Nonexistent Calendar" })
        }.to raise_error(/no calendar named/)
      end

      it "shows where it is going on the confirm row" do
        costco_on(personal)
        tool    = Buddy::Tools[:edit_agenda_item]
        confirm = tool[:confirm].call({ item: "Costco Run", calendar: "Ours" }, ctx)
        label   = tool[:label].call({ item: "Costco Run" }.merge(confirm[:resolved]), ctx)

        expect(label[:sub]).to include("#{personal.name} → Ours 💕")
      end

      it "says it moved rather than updated" do
        costco_on(personal)
        tool = Buddy::Tools[:edit_agenda_item]
        result, = run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours" })

        expect(tool[:receipt].call(result, ctx)).to eq("Moved Costco Run to Ours 💕 ✓")
      end

      it "still edits an item on a calendar shared to the person for editing" do
        partner = create(:user)
        shared  = create(:agenda, user: partner, name: "Theirs")
        shared.agenda_shares.create!(user: user, permission: :editor)
        item = shared.agenda_items.create!(name: "Costco Run", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed)

        run(:edit_agenda_item, { item: "Costco Run", title: "Costco Trip" })

        expect(item.reload.name).to eq("Costco Trip")
      end
    end

    # Prod: "Add Help Richard on the agenda tomorrow" landed as a task, then
    # "let's make it a 3 hour event" got "I can't flip that agenda row from task
    # to event in place here" — so the row was deleted by hand and re-added. Three
    # exchanges for one edit, and the tool was right that it had no way to do it.
    describe "converting between a task and an event" do
      def task_on(agenda, name: "Help Richard")
        agenda.agenda_items.create!(name: name, start_at: at, kind: :task, status: :confirmed)
      end

      it "makes a to-do into an event of the length they asked for" do
        item = task_on(personal)

        run(:edit_agenda_item, { item: "Help Richard", kind: :event, duration: 180 })

        expect(item.reload).to be_event
        expect(item.end_at).to eq(item.start_at + 180.minutes)
      end

      it "gives a conversion with no length the same 30 minutes a new event gets" do
        item = task_on(personal)

        run(:edit_agenda_item, { item: "Help Richard", kind: :event })

        expect(item.reload.end_at).to eq(item.start_at + 30.minutes)
      end

      it "drops the span when an event becomes a to-do" do
        item = costco_on(personal)

        run(:edit_agenda_item, { item: "Costco Run", kind: :task })

        expect(item.reload).to be_task
        expect(item.end_at).to be_nil
      end

      it "leaves an ordinary edit's kind alone" do
        item = task_on(personal)

        run(:edit_agenda_item, { item: "Help Richard", title: "Help Rich" })

        expect(item.reload).to be_task
        expect(item.end_at).to be_nil
      end

      it "refuses to reshape an agenda trigger, which fires an automation" do
        personal.agenda_items.create!(name: "Porch Light", start_at: at, kind: :trigger, status: :confirmed)

        expect {
          run(:edit_agenda_item, { item: "Porch Light", kind: :event })
        }.to raise_error(/can't be converted/)
      end

      it "puts both the kind and the span back on undo" do
        item = task_on(personal)
        result, = run(:edit_agenda_item, { item: "Help Richard", kind: :event, duration: 180 })

        Buddy::Reverter.call(result[:revert])

        expect(item.reload).to be_task
        expect(item.end_at).to be_nil
      end

      it "says what it became rather than just 'updated'" do
        task_on(personal)
        tool = Buddy::Tools[:edit_agenda_item]
        result, = run(:edit_agenda_item, { item: "Help Richard", kind: :event, duration: 180 })

        expect(tool[:receipt].call(result, ctx)).to eq("Help Richard is an event now - 180m ✓")
      end

      it "shows the conversion on the confirm row" do
        task_on(personal)
        tool    = Buddy::Tools[:edit_agenda_item]
        payload = { item: "Help Richard", kind: :event, duration: 180 }
        confirm = tool[:confirm].call(payload, ctx)
        label   = tool[:label].call(payload.merge(confirm[:resolved]), ctx)

        expect(label[:sub]).to include("task → event")
      end
    end

    # The checklist row prefixes itself with what tapping it will do, and calling
    # a to-do an "Event" is wrong in the one word that says whether the thing
    # occupies a span of the day. `kind` in `resolved` is what the row BECOMES,
    # which is what it already is unless the edit is a conversion.
    describe "telling the row whether it's a task or an event" do
      def task_on(agenda)
        agenda.agenda_items.create!(name: "Shower", start_at: at, kind: :task, status: :confirmed)
      end

      it "resolves the kind of the item being edited" do
        task_on(personal)

        _, confirm = run(:edit_agenda_item, { item: "Shower", title: "Long shower" })

        expect(confirm[:resolved][:kind]).to eq("task")
      end

      it "says event for one that is one" do
        costco_on(personal)

        _, confirm = run(:edit_agenda_item, { item: "Costco Run", title: "Costco Trip" })

        expect(confirm[:resolved][:kind]).to eq("event")
      end
    end

    # Level 2: it goes on the calendar the moment Byte proposes it, as a
    # pre-checked row that unchecks back off. Making them tap to confirm every add
    # was a toll on the common case — they'd already said what they wanted, and
    # putting something on a calendar is easy to see and easy to take back.
    describe "an add landing on its own" do
      let!(:convo) {
        user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
      }

      before { allow(MonitorChannel).to receive(:broadcast_to) }

      def propose!(title)
        msg = convo.byte_messages.create!(
          user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
        )
        Buddy::ProposalBuilder.create(
          user:         user,
          byte_message: msg,
          markers:      [{ tool_name: :add_agenda_item, payload: { title: title, at: at.iso8601, kind: "task" } }],
        )
      end

      it "is on the calendar without anyone tapping anything" do
        expect { propose!("Shower") }.to change { AgendaItem.where(name: "Shower").count }.by(1)
      end

      it "leaves a row that's already ticked, and can be unticked" do
        result = propose!("Shower")
        row    = result[:action].buttons.first

        expect(row["status"]).to eq("executed")
        expect(row["undoable"]).to be(true)
      end

      # The undo has to actually reach the item, or the pre-checked row is a
      # promise it can't keep.
      it "takes it back off when the row is unticked" do
        result = propose!("Shower")
        action = result[:action]

        Buddy::ProposalExecutor.undo!(action.id, action.buttons.first["id"])

        expect(AgendaItem.find_by(name: "Shower")).to be_cancelled
      end

      it "puts an edit back the way it was" do
        item = personal.agenda_items.create!(
          name: "Costco Run", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed,
        )
        msg = convo.byte_messages.create!(
          user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current,
        )
        result = Buddy::ProposalBuilder.create(
          user:         user,
          byte_message: msg,
          markers:      [{ tool_name: :edit_agenda_item, payload: { item: "Costco Run", title: "Costco Trip" } }],
        )
        expect(item.reload.name).to eq("Costco Trip")

        action = result[:action]
        Buddy::ProposalExecutor.undo!(action.id, action.buttons.first["id"])

        expect(item.reload.name).to eq("Costco Run")
      end
    end

    describe "add_agenda_item when the thing already exists" do
      it "warns that this looks like a move so the model can switch tools" do
        costco_on(personal)
        tool    = Buddy::Tools[:add_agenda_item]
        confirm = tool[:confirm].call({ title: "Costco Run", at: at, calendar: "Ours" }, ctx)

        expect(confirm[:summary]).to include("already exists")
        expect(confirm[:summary]).to include("edit_agenda_item")
      end

      it "does not warn about an unrelated item at the same time" do
        personal.agenda_items.create!(name: "Dentist", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed)
        tool    = Buddy::Tools[:add_agenda_item]
        confirm = tool[:confirm].call({ title: "Costco Run", at: at }, ctx)

        expect(confirm[:summary]).not_to include("already exists")
      end

      it "still adds, since two real errands can collide" do
        costco_on(personal)

        run(:add_agenda_item, { title: "Costco Run", at: at, calendar: "Ours" })

        expect(AgendaItem.where(name: "Costco Run").count).to eq(2)
      end
    end

    # The other half of prod 4462-4471: once Buddy CAN see the four dinners that
    # exist only as rules, moving one has to move the rule. Changing the single
    # materialized Monday leaves 167 pointing at Alchemibluum, and next Monday
    # is back on the wrong calendar.
    describe "a repeating item" do
      # Every time here is placed relative to now, and the suite runs at
      # whatever o'clock it runs at: late in the evening "3 hours from now" is
      # tomorrow, and every one of these items fell out of today's window, so
      # the block passed and failed by the clock rather than by the filter it
      # is about. Pinned to a Monday morning, which is also what the weekly
      # rules below need in order to have materialized anything.
      around { |example| travel_to(Time.utc(2026, 8, 24, 15, 0)) { example.run } }

      def dinner!(on: personal, day: "mon")
        AgendaSchedule.create!(
          agenda: on, name: "Kevin's meal & pilaf", kind: :event, duration_minutes: 60,
          starts_on: Date.current, start_time: "18:00",
          recurrence: { "freq" => "weekly", "by_day" => [day] }
        )
      end

      it "moves the rule, not just the one occurrence" do
        schedule = dinner!

        run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours", series: "true" })

        expect(schedule.reload.agenda_id).to eq(ours.id)
      end

      it "takes the occurrences it had already made with it" do
        schedule = dinner!
        expect(schedule.reload.agenda_items.count).to be_positive

        run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours", series: "true" })

        expect(schedule.reload.agenda_items.pluck(:agenda_id).uniq).to eq([ours.id])
      end

      # Tue-Fri had no row at all, which is what made them unreachable. The rule
      # is the only thing to edit, so `series` isn't something they have to say.
      it "edits the rule for an occurrence that has no row" do
        # A Friday series, asked about on the Monday the block is pinned to:
        # four days out, well past MATERIALIZE_WINDOW, so nothing has been
        # written for it.
        schedule = dinner!(day: "fri")
        expect(schedule.agenda_items).to be_empty

        run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours" })

        expect(schedule.reload.agenda_id).to eq(ours.id)
      end

      it "says the series moved rather than an item" do
        dinner!
        result, = run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours", series: "true" })

        expect(Buddy::Tools[:edit_agenda_item][:receipt].call(result, ctx))
          .to include("Moved every Kevin's meal & pilaf to Ours 💕")
      end

      it "still changes just the one occurrence when they didn't ask for the series" do
        schedule = dinner!
        item = schedule.reload.agenda_items.first

        run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours" })

        expect(item.reload.agenda_id).to eq(ours.id)
        expect(schedule.reload.agenda_id).to eq(personal.id)
      end

      it "refuses `series` on something that doesn't repeat" do
        costco_on(personal)

        expect {
          run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours", series: "true" })
        }.to raise_error(/isn't a repeating item/)
      end

      # Ending a series is a different ask, and answering it here would take
      # every future occurrence off the calendar under an "updated" receipt.
      it "refuses to cancel a whole series" do
        dinner!

        expect {
          run(:edit_agenda_item, { item: "Kevin's meal", cancelled: "true", series: "true" })
        }.to raise_error(/cancelling a whole series/)
      end
    end

    # Prod 4462-4463: "add the following to the agenda for dinners" put five
    # dinners on Alchemibluum and the reply said "the Dinners calendar", because
    # add fell back to the default for a name nobody has while edit refused.
    # The confirm card DID name the right calendar; the person reads the prose.
    describe "a calendar nobody has" do
      it "refuses rather than landing on the default" do
        expect {
          run(:add_agenda_item, { title: "Kevin's meal & pilaf", at: at, calendar: "Dinners" })
        }.to raise_error(/no calendar named "Dinners"/)
      end

      it "writes nothing while it refuses" do
        expect {
          run(:add_agenda_item, { title: "Kevin's meal & pilaf", at: at, calendar: "Dinners" }) rescue nil
        }.not_to change(AgendaItem, :count)
      end

      it "still lands on the default when no calendar was named" do
        run(:add_agenda_item, { title: "Dentist", at: at })

        expect(AgendaItem.find_by(name: "Dentist").agenda_id).to eq(personal.id)
      end

      it "still reaches a calendar named loosely" do
        run(:add_agenda_item, { title: "Dentist", at: at, calendar: "ours" })

        expect(AgendaItem.find_by(name: "Dentist").agenda_id).to eq(ours.id)
      end

      # The raise in WatchCondition.agenda was unreachable for the same reason:
      # the loose form answers with the default for any name it doesn't know, so
      # a watch on a calendar nobody has quietly watched the first one.
      it "refuses to watch one too" do
        expect {
          Buddy::WatchCondition.resolve({ trigger: :agenda, target: "Dinners" }, ctx)
        }.to raise_error(/not sure which calendar/)
      end
    end

    describe "the default calendar" do
      it "lands on the oldest writable calendar when nothing is chosen" do
        expect(ctx.resolve_writable_agenda(nil)).to eq(personal)
      end

      it "honors the person's choice once they set one" do
        AgendaPreference.for(user).update!(default_agenda_id: ours.id)

        expect(ctx.resolve_writable_agenda(nil)).to eq(ours)
      end

      it "falls back when the chosen calendar is gone" do
        pref = AgendaPreference.for(user)
        pref.update!(default_agenda_id: ours.id)
        ours.destroy

        expect(pref.reload.default_agenda_id).to be_nil
        expect(Buddy::ToolContext.new(user.reload).resolve_writable_agenda(nil)).to eq(personal)
      end

      it "refuses a calendar the person cannot add to" do
        stranger = create(:user)
        theirs   = create(:agenda, user: stranger, name: "Not Yours")
        pref     = AgendaPreference.for(user)
        pref.default_agenda_id = theirs.id

        expect(pref).not_to be_valid
        expect(pref.errors[:default_agenda_id].join).to include("calendar you can add to")
      end

      it "stops flagging the calendar on the confirm row once it IS the default" do
        AgendaPreference.for(user).update!(default_agenda_id: ours.id)
        tool    = Buddy::Tools[:add_agenda_item]
        confirm = tool[:confirm].call({ title: "Dentist", at: at, calendar: "Ours" }, ctx)

        expect(confirm[:resolved][:agenda_default]).to be(true)
      end
    end
  end

  # Prod 1258-1261: "add them both now" put Shower and Laundry on the agenda as
  # TASKS, and both rendered as "Thu Jul 30, 2:49 PM-3:19 PM". A task has no
  # duration - it sits at one moment - so the half-hour block was invented by the
  # tool, not asked for.
  describe "the shape of an item" do
    let(:user) { create(:user) }
    let(:at)   { Time.current.tomorrow.change(hour: 13) }

    before { allow(AgendaTravelChainSyncWorker).to receive(:perform_async) }

    def ctx
      Buddy::ToolContext.new(user)
    end

    def run(tool_name, payload)
      tool    = Buddy::Tools[tool_name]
      confirm = tool[:confirm].call(payload, ctx)
      merged  = payload.merge(confirm[:resolved] || {})
      { result: tool[:execute].call(merged, ctx), label: tool[:label].call(merged, ctx), merged: merged }
    end

    describe "add_agenda_item" do
      it "leaves a task with no end time at all" do
        out  = run(:add_agenda_item, { title: "Shower", at: at, kind: :task })
        item = AgendaItem.find(out[:result][:agenda_item_id])

        expect(item.kind).to eq("task")
        expect(item.start_at).to be_within(1.second).of(at)
        expect(item.end_at).to be_nil
      end

      it "still gives an event its span" do
        out  = run(:add_agenda_item, { title: "Dinner", at: at, kind: :event, duration: 90 })
        item = AgendaItem.find(out[:result][:agenda_item_id])

        expect(item.end_at).to be_within(1.second).of(at + 90.minutes)
      end

      it "ignores a duration handed to a task" do
        out  = run(:add_agenda_item, { title: "Laundry", at: at, kind: :task, duration: 45 })
        item = AgendaItem.find(out[:result][:agenda_item_id])

        expect(item.end_at).to be_nil
      end

      it "shows one time on the confirm row for a task, a range for an event" do
        local = at.in_time_zone(user.timezone)
        task  = run(:add_agenda_item, { title: "Shower", at: at, kind: :task })
        event = run(:add_agenda_item, { title: "Dinner", at: at, kind: :event, duration: 90 })

        expect(task[:label][:sub]).to include(local.strftime("%-I:%M %p"))
        expect(task[:label][:sub]).not_to include("–")
        expect(event[:label][:sub]).to include("#{local.strftime("%-I:%M %p")}–#{(local + 90.minutes).strftime("%-I:%M %p")}")
      end
    end

    describe "edit_agenda_item" do
      let(:agenda) { user.agendas.order(:id).first }

      it "does not grow an end time on a task that's being retimed" do
        task = agenda.agenda_items.create!(name: "Shower", start_at: at, kind: :task, status: :confirmed)

        run(:edit_agenda_item, { item: "Shower", at: (at + 2.hours), duration: 45 })

        expect(task.reload.start_at).to be_within(1.second).of(at + 2.hours)
        expect(task.end_at).to be_nil
      end

      # end_at doesn't move on its own, so pushing an event later used to leave it
      # behind the new start and fail the end-after-start validation.
      it "carries an event's existing length along when only the start moves" do
        event = agenda.agenda_items.create!(name: "Dinner", start_at: at, end_at: at + 90.minutes, kind: :event, status: :confirmed)

        run(:edit_agenda_item, { item: "Dinner", at: (at + 3.hours) })

        expect(event.reload.start_at).to be_within(1.second).of(at + 3.hours)
        expect(event.end_at).to be_within(1.second).of(at + 3.hours + 90.minutes)
      end
    end
  end

  # What time an agenda item actually lands on.
  #
  # Prod Aug 3: "Can you move it earlier?" was answered with "Shower's now at
  # **4:45 PM**" and an `at` of 2026-08-03T10:45:00Z, which on a UTC-6 calendar is
  # 4:45 AM - four hours before the person woke up and eleven hours before the
  # reply announcing it. Two separate defects put it there, and either one alone
  # still writes a wrong time:
  #
  #   1. The model hand-converting to UTC and getting the sign backwards.
  #   2. A naive ISO string being parsed as UTC, because Time.zone is UTC
  #      app-wide, so the wall clock the model meant got shifted by the offset.
  describe "times" do
    let(:user) { create(:user) }
    let(:zone) { ActiveSupport::TimeZone["America/Denver"] }
    let(:now)  { zone.local(2026, 8, 3, 8, 47) }

    before { allow(AgendaTravelChainSyncWorker).to receive(:perform_async) }

    def ctx = Buddy::ToolContext.new(user)

    def cast(at)
      tool = Buddy::Tools[:add_agenda_item]
      payload, errors = Buddy::Tools.validate_payload(
        tool, { title: "Shower", at: at, kind: :task }, zone: Buddy::Day.zone(user)
      )
      raise errors.join("; ") if errors.any?

      payload
    end

    # confirm is where the time is settled, so the checklist row can't show one
    # thing while the record gets another.
    def settled(at, tool_name=:add_agenda_item, extra={})
      tool = Buddy::Tools[tool_name]
      payload = cast(at).merge(extra)
      confirm = tool[:confirm].call(payload, ctx)
      [payload.merge(confirm[:resolved] || {}), tool]
    end

    def local(payload) = payload[:at].in_time_zone(zone).strftime("%a %-I:%M %p")

    describe "reading the time the model wrote" do
      it "takes a bare ISO as the person's wall clock, not the server's UTC" do
        expect(cast("2026-08-03T16:45:00")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")
      end

      it "still treats an explicit offset as authoritative" do
        expect(cast("2026-08-03T22:45:00Z")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")
        expect(cast("2026-08-03T16:45:00-06:00")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")
      end

      # The old behaviour, still what you get with no zone in scope (routine
      # validation, which only cares about shape).
      it "falls back to UTC when there's no user zone to read it in" do
        tool = Buddy::Tools[:add_agenda_item]
        payload, = Buddy::Tools.validate_payload(tool, { title: "Shower", at: "2026-08-03T16:45:00" })

        expect(payload[:at].utc.strftime("%-I:%M %p")).to eq("4:45 PM")
      end
    end

    # Nothing gets nudged forward any more. A time already gone today lands at
    # NOW — see ToolContext#resolve_calendar_time for why the 12-hour bump went.
    describe "a same-day time that's already gone" do
      it "puts an hour that's already passed at the current time" do
        payload, = Timecop.freeze(now) { settled("2026-08-03T04:45:00") }

        expect(local(payload)).to eq("Mon 8:47 AM")
      end

      # Prod 966/967: no hour was named at all, so the model wrote the wall clock
      # and it resolved a few seconds late. That used to become 11:11 PM.
      it "leaves a timestamp that IS now where it is" do
        moment = zone.local(2026, 8, 3, 8, 47, 20)
        payload, = Timecop.freeze(moment) { settled("2026-08-03T08:47:00") }

        expect(local(payload)).to eq("Mon 8:47 AM")
      end

      it "leaves an ordinary future time alone" do
        payload, = Timecop.freeze(now) { settled("2026-08-03T17:15:00") }

        expect(local(payload)).to eq("Mon 5:15 PM")
      end

      # A deliberate back-date to another day is a real thing to want, and nothing
      # about it looks like a half-day slip.
      it "leaves a time on an earlier day alone" do
        payload, = Timecop.freeze(now) { settled("2026-08-02T04:45:00") }

        expect(local(payload)).to eq("Sun 4:45 AM")
      end

      # Late at night is where the old bump was at its worst: it either wrapped
      # past midnight or gave up. Now it just says now.
      it "says now rather than wrapping a late-night item" do
        late = zone.local(2026, 8, 3, 23, 30)
        payload, = Timecop.freeze(late) { settled("2026-08-03T01:00:00") }

        expect(local(payload)).to eq("Mon 11:30 PM")
      end

      # The one thing that must never happen again: an item landing half a day
      # from anything that was said.
      it "never puts an item twelve hours out" do
        %w[2026-08-03T04:45:00 2026-08-03T08:30:00 2026-08-03T10:45:00Z].each { |iso|
          payload, = Timecop.freeze(now) { settled(iso) }
          drift = (payload[:at] - now).abs

          expect(drift).to be < 1.hour, "#{iso} landed #{(drift / 3600.0).round(1)}h from now"
        }
      end
    end

    # The row IS the receipt for a level-2 tool, so a correction that the row
    # doesn't show is a correction nobody can check.
    describe "what the person sees" do
      it "shows the time it actually settled on, not the one that was asked for" do
        payload, tool = Timecop.freeze(now) { settled("2026-08-03T04:45:00") }
        label = tool[:label].call(payload, ctx)

        expect(label[:sub]).to include("8:47 AM")
        expect(label[:sub]).not_to include("4:45")
      end

      it "names the time in the add receipt" do
        payload, tool = Timecop.freeze(now) { settled("2026-08-03T17:15:00") }
        result = Timecop.freeze(now) { tool[:execute].call(payload, ctx) }

        expect(tool[:receipt].call(result, ctx)).to include("Mon 5:15 PM")
      end
    end

    describe "moving one that's already on the calendar" do
      let!(:item) {
        user.agendas.first.agenda_items.create!(
          name: "Shower", start_at: zone.local(2026, 8, 3, 17, 15), kind: :task, status: :confirmed,
        )
      }

      # An edit takes the same rule as an add: a moved-to time that's already gone
      # today lands at now, never half a day out.
      it "moves it to now rather than twelve hours on" do
        tool = Buddy::Tools[:edit_agenda_item]
        payload = { item: "Shower", at: cast("2026-08-03T04:45:00")[:at] }
        merged  = Timecop.freeze(now) { payload.merge(tool[:confirm].call(payload, ctx)[:resolved]) }

        Timecop.freeze(now) { tool[:execute].call(merged, ctx) }

        expect(item.reload.start_at.in_time_zone(zone).strftime("%-I:%M %p")).to eq("8:47 AM")
      end

      it "says the new time in the receipt rather than a bare Updated" do
        tool = Buddy::Tools[:edit_agenda_item]
        payload = { item: "Shower", at: cast("2026-08-03T19:00:00")[:at] }
        merged  = Timecop.freeze(now) { payload.merge(tool[:confirm].call(payload, ctx)[:resolved]) }
        result  = Timecop.freeze(now) { tool[:execute].call(merged, ctx) }

        expect(tool[:receipt].call(result, ctx)).to include("7:00 PM")
      end
    end

    # Prod 5144-5147: "Can you move the Orchard event today? We want to LEAVE at
    # 4." The start went to 4:00 PM and the reply quoted "about 20 minutes of
    # drive" for a 32-minute one; the correction then set the start to 4:28 PM,
    # which was the OLD leave time, and called that a leave time. `at` is always
    # a start, so there was no correct call available.
    describe "a leave time, which is not a start time" do
      let(:tool) { Buddy::Tools[:edit_agenda_item] }

      # 31-minute drive, 0 arrive-early, exactly as agenda_items 1069.
      let!(:orchard) {
        user.agendas.first.agenda_items.create!(
          name:                 "Orchard",
          kind:                 :event,
          start_at:             zone.local(2026, 8, 3, 17, 0),
          end_at:               zone.local(2026, 8, 3, 18, 0),
          location:             "Orchard",
          arrive_early_minutes: 0,
          metadata:             { "travel" => { "travel_seconds" => 1860 } },
        )
      }

      def leave!(at_str, **extra)
        payload = { item: "Orchard", leave_at: cast(at_str)[:at], **extra }
        merged  = Timecop.freeze(now) { payload.merge(tool[:confirm].call(payload, ctx)[:resolved]) }
        [merged, Timecop.freeze(now) { tool[:execute].call(merged, ctx) }]
      end

      it "works the start back from the drive time" do
        merged, = leave!("2026-08-03T16:00:00")

        expect(merged[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:31 PM")
      end

      it "writes that start to the row" do
        leave!("2026-08-03T16:00:00")

        expect(orchard.reload.start_at.in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:31 PM")
      end

      it "adds arrive-early on top of the drive" do
        orchard.update!(arrive_early_minutes: 10)
        merged, = leave!("2026-08-03T16:00:00")

        expect(merged[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:41 PM")
      end

      # The half the original reply got wrong: it named one time and called it
      # the other.
      it "names BOTH times in the receipt" do
        _merged, result = leave!("2026-08-03T16:00:00")
        receipt = tool[:receipt].call(result.symbolize_keys, ctx)

        expect(receipt).to include("leave 4:00 PM")
        expect(receipt).to include("4:31 PM")
      end

      it "shows both on the chip too" do
        merged, = leave!("2026-08-03T16:00:00")

        expect(tool[:label].call(merged, ctx)[:sub]).to include("leave 4:00 PM", "starts")
      end

      it "refuses when there is no drive time to work back from" do
        orchard.update!(metadata: {})

        expect { leave!("2026-08-03T16:00:00") }
          .to raise_error(/don't have a drive time.*meant the start/m)
      end

      it "refuses a start and a leave time in the same call" do
        expect { leave!("2026-08-03T16:00:00", at: cast("2026-08-03T16:00:00")[:at]) }
          .to raise_error(/not both/)
      end

      it "leaves a plain `at` alone" do
        payload = { item: "Orchard", at: cast("2026-08-03T16:00:00")[:at] }
        merged  = Timecop.freeze(now) { payload.merge(tool[:confirm].call(payload, ctx)[:resolved]) }

        expect(merged[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:00 PM")
        expect(merged[:leave_from]).to be_nil
      end
    end
  end
end
