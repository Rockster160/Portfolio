require "rails_helper"

RSpec.describe "Buddy agenda tools" do
  # Buddy putting things on, and moving things between, calendars.
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
      tool     = Buddy::Tools[tool_name]
      confirm  = tool[:confirm].call(payload, ctx)
      resolved = payload.merge(confirm[:resolved] || {})
      # Where Turn#resolve asks it, and the only place it is asked.
      tool[:guard]&.call(resolved, ctx)
      [tool[:execute].call(resolved, ctx), confirm]
    end

    def costco_on(agenda)
      agenda.agenda_items.create!(name: "Costco Run", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed)
    end

    describe "edit_agenda_item moving between calendars" do
      it "moves the existing item instead of leaving a second one behind, shows it on the row, and undoes", :aggregate_failures do
        item = costco_on(personal)
        tool = Buddy::Tools[:edit_agenda_item]
        confirm = tool[:confirm].call({ item: "Costco Run", calendar: "Ours" }, ctx)
        expect(tool[:label].call({ item: "Costco Run" }.merge(confirm[:resolved]), ctx)[:sub])
          .to include("#{personal.name} → Ours 💕")

        result, = run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours" })

        expect(item.reload.agenda_id).to eq(ours.id)
        expect(AgendaItem.where(name: "Costco Run").count).to eq(1)

        Buddy::Reverter.call(result[:revert])

        expect(item.reload.agenda_id).to eq(personal.id)
      end

      it "refuses a calendar name that matches nothing rather than picking one" do
        costco_on(personal)

        expect {
          run(:edit_agenda_item, { item: "Costco Run", calendar: "Nonexistent Calendar" })
        }.to raise_error(/no calendar named/)
      end

      # Writing the same id back would still be an executed edit, so the next
      # turn could claim the move again.
      it "refuses a move to the calendar it is already on" do
        costco_on(ours)

        expect {
          run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours" })
        }.to raise_error(/already on Ours/)
      end

      # ...and only when the move was the whole request. The confirm row is what
      # the next turn reads back, so the no-op move stays off it.
      it "still makes the other edit when the calendar clause changes nothing, without claiming a move" do
        item    = costco_on(ours)
        payload = { item: "Costco Run", calendar: "Ours", title: "Costco Trip" }

        expect(Buddy::Tools[:edit_agenda_item][:confirm].call(payload, ctx)[:resolved]).not_to include(:agenda_id, :agenda_from)

        run(:edit_agenda_item, payload)

        expect(item.reload).to have_attributes(name: "Costco Trip", agenda_id: ours.id)
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

    # The same-name rule's intent is the soonest, not the oldest row.
    describe "two of the same name on different dates" do
      def shower_at(when_at)
        personal.agenda_items.create!(
          name: "Shower", start_at: when_at, end_at: when_at + 30.minutes,
          kind: :event, status: :confirmed,
        )
      end

      it "edits the soonest one rather than the oldest row" do
        old  = shower_at(4.months.ago)
        soon = shower_at(2.hours.from_now)

        run(:edit_agenda_item, { item: "Shower", title: "Shower and stretch" })

        expect(soon.reload.name).to eq("Shower and stretch")
        expect(old.reload.name).to eq("Shower")
      end

      # One that already happened is still reachable when it is all there is -
      # and then it is the most recent of them, not the first ever.
      it "falls back to the most recent past one when nothing is coming" do
        long_ago = shower_at(4.months.ago)
        recent   = shower_at(2.days.ago)

        run(:edit_agenda_item, { item: "Shower", title: "Shower and stretch" })

        expect(recent.reload.name).to eq("Shower and stretch")
        expect(long_ago.reload.name).to eq("Shower")
      end
    end

    describe "converting between a task and an event" do
      def task_on(agenda, name: "Help Richard")
        agenda.agenda_items.create!(name: name, start_at: at, kind: :task, status: :confirmed)
      end

      it "makes a to-do into an event of the length they asked for, shows it, and undoes both kind and span", :aggregate_failures do
        item    = task_on(personal)
        tool    = Buddy::Tools[:edit_agenda_item]
        payload = { item: "Help Richard", kind: :event, duration: 180 }
        expect(tool[:label].call(payload.merge(tool[:confirm].call(payload, ctx)[:resolved]), ctx)[:sub])
          .to include("task → event")

        result, = run(:edit_agenda_item, payload)

        expect(item.reload).to be_event
        expect(item.end_at).to eq(item.start_at + 180.minutes)

        Buddy::Reverter.call(result[:revert])

        expect(item.reload).to be_task
        expect(item.end_at).to be_nil
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
        costco_on(personal)

        _, task_confirm  = run(:edit_agenda_item, { item: "Shower", title: "Long shower" })
        _, event_confirm = run(:edit_agenda_item, { item: "Costco Run", title: "Costco Trip" })

        expect(task_confirm[:resolved][:kind]).to eq("task")
        expect(event_confirm[:resolved][:kind]).to eq("event")
      end
    end

    # Level 2: it goes on the calendar the moment Byte proposes it, as a
    # pre-checked row that unchecks back off.
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

      it "is on the calendar without a tap, as a ticked row that unticking cancels" do
        result = nil
        expect { result = propose!("Shower") }.to change { AgendaItem.where(name: "Shower").count }.by(1)

        action = result[:action]
        row    = action.buttons.first
        expect(row["status"]).to eq("executed")
        expect(row["undoable"]).to be(true)

        Buddy::ProposalExecutor.undo!(action.id, row["id"])

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

    # "No need to be early" is an answer, not a missing argument, and 0 is
    # `present?` - which is why nothing here reads `.presence`.
    describe "how early to be" do
      def early_of(name)
        AgendaItem.find_by(name: name).arrive_early_minutes
      end

      it "is five by default, with or without a place, and takes a named number including nought" do
        [
          [{ title: "Eye Follow Up", at: at }, 5],
          [{ title: "Coffee", at: at, location: "Lucky Ones" }, 5],
          [{ title: "Dentist", at: at, arrive_early: 10 }, 10],
          [{ title: "Walk", at: at, arrive_early: 0 }, 0],
        ].each { |payload, expected|
          run(:add_agenda_item, payload)
          expect(early_of(payload[:title])).to eq(expected), payload.inspect
        }
      end

      it "carries the default onto a series rather than zeroing it" do
        run(:add_agenda_item, { title: "Standup", at: at, repeat: "weekdays" })

        expect(AgendaSchedule.find_by(name: "Standup").arrive_early_minutes).to eq(5)
      end

      # No location, no drive time, nothing to work back through - and none of
      # that matters.
      it "sets it on an item that has no drive time at all" do
        item = personal.agenda_items.create!(
          name: "Eye Follow Up", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed
        )

        expect {
          run(:edit_agenda_item, { item: "Eye Follow Up", arrive_early: 10 })
        }.not_to raise_error

        expect(item.reload.arrive_early_minutes).to eq(10)
      end

      it "changes it on the whole rule when they asked for the series" do
        schedule = personal.agenda_schedules.create!(
          name: "Standup", kind: :event, duration_minutes: 15,
          starts_on: Date.current, start_time: "09:00",
          recurrence: { "freq" => "weekly", "by_day" => ["mon"] }, arrive_early_minutes: 5
        )

        run(:edit_agenda_item, { item: "Standup", arrive_early: 20, series: "true" })

        expect(schedule.reload.arrive_early_minutes).to eq(20)
      end
    end

    describe "add_agenda_item when the thing already exists" do
      it "points at edit_agenda_item when the same item is on another calendar, and not for an unrelated one" do
        costco_on(personal)
        personal.agenda_items.create!(name: "Dentist", start_at: at, end_at: at + 30.minutes, kind: :event, status: :confirmed)
        tool = Buddy::Tools[:add_agenda_item]

        expect(tool[:confirm].call({ title: "Costco Run", at: at, calendar: "Ours" }, ctx)[:summary]).to include("edit_agenda_item")
        expect(tool[:confirm].call({ title: "Lunch", at: at }, ctx)[:summary]).not_to include("edit_agenda_item")
      end

      it "still adds, since two real errands can collide" do
        costco_on(personal)

        run(:add_agenda_item, { title: "Costco Run", at: at, calendar: "Ours" })

        expect(AgendaItem.where(name: "Costco Run").count).to eq(2)
      end
    end

    # The note above is the right answer for a NEAR miss; the exact one is
    # refused, because being told about it was not enough.
    describe "adding the row that is already there" do
      it "refuses instead of making a second copy, whatever the capitalization" do
        costco_on(personal)

        expect { run(:add_agenda_item, { title: "Costco Run", at: at }) }.to raise_error(/already on.*edit_agenda_item|edit_agenda_item.*already on/m)
        expect { run(:add_agenda_item, { title: "costco run", at: at }) }.to raise_error(/already on/)

        expect(AgendaItem.where(name: "Costco Run").count).to eq(1)
      end

      # Scoped to the calendar, because "put it on Ours as well" is a real ask.
      # A cancelled row is a tombstone, and a repeat writes a rule, not a row.
      it "lets it through at another time, on another calendar, over a cancelled row, or as a series" do
        costco_on(personal)
        costco_on(personal).update!(status: :cancelled, start_at: at + 2.hours, end_at: at + 150.minutes)

        run(:add_agenda_item, { title: "Costco Run", at: at + 1.hour })
        run(:add_agenda_item, { title: "Costco Run", at: at, calendar: "Ours" })
        run(:add_agenda_item, { title: "Costco Run", at: at + 2.hours })
        run(:add_agenda_item, { title: "Costco Run", at: at, repeat: "weekly:monday" })

        expect(AgendaItem.where(name: "Costco Run", status: :confirmed, agenda_schedule_id: nil).count).to eq(4)
        expect(AgendaSchedule.where(name: "Costco Run").count).to eq(1)
      end
    end

    # `hint_date` given the date it is moving TO would narrow the lookup to a
    # day the item is not on yet; the fallback is a second pass with one filter
    # fewer, so a hint that DOES match still decides.
    describe "a date hint that matches nothing" do
      it "still finds and moves the item the hint was meant to tell apart" do
        item  = costco_on(personal)
        moved = at + 5.days

        expect(ctx.resolve_agenda_item("Costco Run", hint_date: moved.to_date.to_s)&.id).to eq(item.id)
        expect {
          run(:edit_agenda_item, { item: "Costco Run", hint_date: moved.to_date.to_s, at: moved })
        }.not_to raise_error

        expect(item.reload.start_at).to be_within(1.minute).of(moved)
      end

      it "leaves a hint that matches doing its job" do
        early = costco_on(personal)
        late  = personal.agenda_items.create!(
          name: "Costco Run", start_at: at + 5.days, end_at: at + 5.days + 30.minutes,
          kind: :event, status: :confirmed
        )

        expect(ctx.resolve_agenda_item("Costco Run", hint_date: late.start_at.to_date.to_s)&.id).to eq(late.id)
        expect(ctx.resolve_agenda_item("Costco Run", hint_date: early.start_at.to_date.to_s)&.id).to eq(early.id)
      end
    end

    describe "a repeating item" do
      # Pinned to a Monday morning, which is what the weekly rules below need in
      # order to have materialized anything.
      around { |example| travel_to(Time.utc(2026, 8, 24, 15, 0)) { example.run } }

      def dinner!(on: personal, day: "mon")
        AgendaSchedule.create!(
          agenda: on, name: "Kevin's meal & pilaf", kind: :event, duration_minutes: 60,
          starts_on: Date.current, start_time: "18:00",
          recurrence: { "freq" => "weekly", "by_day" => [day] }
        )
      end

      it "moves the rule, and the occurrences it had already made, when asked for the series" do
        schedule = dinner!
        expect(schedule.reload.agenda_items.count).to be_positive

        run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours", series: "true" })

        expect(schedule.reload.agenda_id).to eq(ours.id)
        expect(schedule.agenda_items.pluck(:agenda_id).uniq).to eq([ours.id])
      end

      # An occurrence past MATERIALIZE_WINDOW has no row yet; editing it must
      # still change only THAT date. The person cannot see which dates have rows.
      describe "a date that hasn't been written down yet" do
        # A Friday series, asked about on the Monday the block is pinned to:
        # four days out, so nothing has been materialized for it.
        let!(:friday) { dinner!(day: "fri") }

        # The new row is an exception to its rule, and the original date comes
        # off the rule, or the evening would show up twice.
        it "changes THAT DATE as an exception and leaves the rule alone", :aggregate_failures do
          expect(friday.agenda_items).to be_empty

          run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours" })

          made = AgendaItem.find_by(agenda_schedule_id: friday.id)
          expect(friday.reload.agenda_id).to eq(personal.id)
          expect(AgendaItem.where(agenda_schedule_id: friday.id).pluck(:agenda_id)).to eq([ours.id])
          expect(made.detached_at).to be_present
          expect(made.original_start_at).to be_present
          expect(friday.recurrence["excluded_dates"])
            .to include(made.original_start_at.in_time_zone(user.timezone).to_date.iso8601)
        end

        it "still moves every one of them when they ask for the series" do
          run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours", series: "true" })

          expect(friday.reload.agenda_id).to eq(ours.id)
        end

        # Undoing has to put it back in the cycle. Rewinding the FIELDS would
        # leave a detached row holding the rule's own values beside an excluded
        # date — invisible, and skipped by the next change to the series.
        it "goes back on its normal schedule when undone" do
          result, = run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours" })
          made = AgendaItem.find_by(agenda_schedule_id: friday.id)

          Buddy::Reverter.call(result[:revert])

          expect(AgendaItem.exists?(made.id)).to be(false)
          expect(friday.reload.recurrence["excluded_dates"].to_a).to be_empty
        end
      end

      it "still changes just the one occurrence when they didn't ask for the series" do
        schedule = dinner!
        item = schedule.reload.agenda_items.first

        run(:edit_agenda_item, { item: "Kevin's meal", calendar: "Ours" })

        expect(item.reload.agenda_id).to eq(ours.id)
        expect(schedule.reload.agenda_id).to eq(personal.id)
      end

      # On a one-off there is no rule, so `series` is redundant rather than wrong.
      it "just moves a one-off when they ask for the series of something that doesn't repeat" do
        item = costco_on(personal)

        run(:edit_agenda_item, { item: "Costco Run", calendar: "Ours", series: "true" })

        expect(item.reload.agenda_id).to eq(ours.id)
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

    # A name nobody has is a question, not a silent landing on the default.
    describe "a calendar nobody has" do
      it "refuses rather than landing on the default, and writes nothing" do
        expect {
          expect {
            run(:add_agenda_item, { title: "Kevin's meal & pilaf", at: at, calendar: "Dinners" })
          }.to raise_error(/no calendar named "Dinners"/)
        }.not_to change(AgendaItem, :count)
      end

      it "still lands on the default when no calendar was named, and reaches one named loosely" do
        run(:add_agenda_item, { title: "Dentist", at: at })
        run(:add_agenda_item, { title: "Checkup", at: at, calendar: "ours" })

        expect(AgendaItem.find_by(name: "Dentist").agenda_id).to eq(personal.id)
        expect(AgendaItem.find_by(name: "Checkup").agenda_id).to eq(ours.id)
      end

      it "refuses to watch one too" do
        expect {
          Buddy::WatchCondition.resolve({ trigger: :agenda, target: "Dinners" }, ctx)
        }.to raise_error(/not sure which calendar/)
      end
    end

    describe "the default calendar" do
      it "lands on the oldest writable calendar until the person chooses one" do
        expect(ctx.resolve_writable_agenda(nil)).to eq(personal)

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
        expect(pref.errors[:default_agenda_id]).to be_present
      end

      it "stops flagging the calendar on the confirm row once it IS the default" do
        AgendaPreference.for(user).update!(default_agenda_id: ours.id)
        tool    = Buddy::Tools[:add_agenda_item]
        confirm = tool[:confirm].call({ title: "Dentist", at: at, calendar: "Ours" }, ctx)

        expect(confirm[:resolved][:agenda_default]).to be(true)
      end
    end
  end

  # A task has no duration - it sits at one moment.
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
      it "leaves a task with no end time at all, even when handed a duration" do
        out  = run(:add_agenda_item, { title: "Shower", at: at, kind: :task, duration: 45 })
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

      it "shows one time on the confirm row for a task, a range for an event" do
        local = at.in_time_zone(user.timezone)
        task  = run(:add_agenda_item, { title: "Shower", at: at, kind: :task })
        event = run(:add_agenda_item, { title: "Dinner", at: at, kind: :event, duration: 90 })

        expect(task[:label][:sub]).to include(Buddy::Clock.at(local))
        expect(task[:label][:sub]).not_to include("–")
        expect(event[:label][:sub]).to include(Buddy::Clock.range(local, local + 90.minutes))
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

  # What time an agenda item actually lands on. Time.zone is UTC app-wide, so
  # a naive ISO string must be read in the person's zone, not the server's.
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
      # With no zone in scope (routine validation, which only cares about
      # shape) it falls back to UTC.
      it "takes a bare ISO as the person's wall clock, an explicit offset as given, and UTC with no zone" do
        expect(cast("2026-08-03T16:45:00")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")
        expect(cast("2026-08-03T22:45:00Z")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")
        expect(cast("2026-08-03T16:45:00-06:00")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")

        payload, = Buddy::Tools.validate_payload(Buddy::Tools[:add_agenda_item], { title: "Shower", at: "2026-08-03T16:45:00" })
        expect(payload[:at].utc.strftime("%-I:%M %p")).to eq("4:45 PM")
      end
    end

    # Nothing gets nudged forward any more. A time already gone today lands at
    # NOW — see ToolContext#resolve_calendar_time for why the 12-hour bump went.
    describe "a same-day time that's already gone" do
      # A deliberate back-date to another day is a real thing to want; an item
      # must never land half a day from anything that was said.
      it "puts an hour already gone today at now, and leaves now, the future and other days alone" do
        [
          [now, "2026-08-03T04:45:00", "Mon 8:47 AM"],
          [zone.local(2026, 8, 3, 8, 47, 20), "2026-08-03T08:47:00", "Mon 8:47 AM"],
          [now, "2026-08-03T17:15:00", "Mon 5:15 PM"],
          [now, "2026-08-02T04:45:00", "Sun 4:45 AM"],
          [zone.local(2026, 8, 3, 23, 30), "2026-08-03T01:00:00", "Mon 11:30 PM"],
          [now, "2026-08-03T10:45:00Z", "Mon 8:47 AM"],
        ].each { |frozen, iso, expected|
          payload, = Timecop.freeze(frozen) { settled(iso) }
          expect(local(payload)).to eq(expected), "#{iso} at #{frozen}"
        }
      end
    end

    # The row IS the receipt for a level-2 tool, so a correction that the row
    # doesn't show is a correction nobody can check.
    it "shows the time it actually settled on, not the one that was asked for" do
      payload, tool = Timecop.freeze(now) { settled("2026-08-03T04:45:00") }
      label = tool[:label].call(payload, ctx)

      expect(label[:sub]).to include("8:47am")
      expect(label[:sub]).not_to include("4:45")
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
    end

    # `at` is always a start; a leave time is worked back from the drive, and a
    # drive the app can measure is fetched rather than asked for.
    describe "looking a drive time up" do
      let(:tool)     { Buddy::Tools[:check_travel_time] }
      let(:personal) { user.agendas.order(:id).first }
      let(:starts)   { zone.local(2026, 8, 4, 13, 0) }

      def orchard!(travel: nil, agenda: personal, location: "Rowley's Red Barn")
        agenda.agenda_items.create!(
          name: "Orchard", kind: :event, location: location, arrive_early_minutes: 0,
          start_at: starts, end_at: starts + 1.hour,
          metadata: travel ? { "travel" => travel } : {}
        )
      end

      def check
        payload = { item: "Orchard" }
        merged  = payload.merge(tool[:confirm].call(payload, ctx)[:resolved])
        tool[:execute].call(merged, ctx)
      end

      def clock(time) = Buddy::Clock.at(time, zone: zone)

      it "reports a drive it already knows without going back out for it" do
        orchard!(travel: { "travel_seconds" => 1860, "travel_minutes" => 31 })
        expect(AgendaTravelChain).not_to receive(:refresh_for)

        expect(check[:drive_min]).to eq(31)
      end

      it "goes and measures one it hasn't got" do
        item = orchard!
        allow(AgendaTravelChain).to receive(:refresh_for) { |i|
          i.update!(metadata: { "travel" => { "travel_seconds" => 1200 } })
        }

        result = check

        expect(AgendaTravelChain).to have_received(:refresh_for).with(item)
        expect(result[:drive_min]).to eq(20)
      end

      # The whole point of the tool: what comes back is enough for the very next
      # call to set a leave time, which used to be refused outright.
      it "hands back a leave time edit_agenda_item can use" do
        orchard!(travel: { "travel_seconds" => 1860, "leave_at" => (starts - 31.minutes).to_i })

        expect(check[:leave_by]).to eq(clock(starts - 31.minutes))
      end

      # Spaced and rounded, so nothing downstream has to do the arithmetic.
      it "hands back a follow-on that is already spaced and rounded" do
        orchard!(travel: { "travel_seconds" => 1860, "post_travel_seconds" => 1860 })
        home = starts + 1.hour + 31.minutes

        result = check

        expect(result[:home_by]).to eq(clock(home))
        expect(result[:follow_on]).to eq(clock(Buddy::FollowUp.after(home)))
      end

      it "refuses something with nowhere to drive to" do
        orchard!(location: "")

        expect { check }.to raise_error(/no location/)
      end

      it "says so plainly when the address can't be placed" do
        orchard!
        allow(AgendaTravelChain).to receive(:refresh_for)

        result = check

        expect(result[:unresolved]).to be(true)
      end

      # Her drive home is a fact about when the house is his again. A viewer
      # share is out of `editable_agendas`, which is right for a write and wrong
      # for a look.
      it "reads an item on a calendar shared in as a viewer" do
        partner = create(:user)
        hers = create(:agenda, user: partner)
        AgendaShare.create!(agenda: hers, user: user, permission: :viewer)
        orchard!(travel: { "travel_seconds" => 1860 }, agenda: hers)

        expect(check[:drive_min]).to eq(31)
      end
    end

    describe "a leave time, which is not a start time" do
      let(:tool) { Buddy::Tools[:edit_agenda_item] }

      # 31-minute drive, 0 arrive-early.
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

      it "works the start back from the drive time, writes it, and shows the leave time on the chip" do
        merged, = leave!("2026-08-03T16:00:00")

        expect(merged[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:31 PM")
        expect(orchard.reload.start_at.in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:31 PM")
        expect(tool[:label].call(merged, ctx)[:sub]).to include("leave 4pm")
      end

      it "adds arrive-early on top of the drive" do
        orchard.update!(arrive_early_minutes: 10)
        merged, = leave!("2026-08-03T16:00:00")

        expect(merged[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:41 PM")
      end

      # "Leave at 4 and let's be 10 minutes early": the buffer being written this
      # turn is the one to work back through, not the row's.
      it "works back through the arrive-early it is being given, not the old one" do
        merged, = leave!("2026-08-03T16:00:00", arrive_early: 10)

        expect(merged[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:41 PM")
        expect(orchard.reload.arrive_early_minutes).to eq(10)
      end

      it "refuses when there is no drive time to work back from" do
        orchard.update!(metadata: {})

        expect { leave!("2026-08-03T16:00:00") }
          .to raise_error(/drive time/)
      end

      # The legacy pair — `travel_minutes` + `travel_location` — is what the Jil
      # refresh task writes, and it has no seconds in it.
      it "works back from a minutes-only drive time" do
        orchard.update!(metadata: { "travel" => { "travel_minutes" => 47, "travel_location" => "Orchard" } })

        merged, = leave!("2026-08-03T16:00:00")

        expect(merged[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:47 PM")
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

  # `leave_at` on add, so a departure time never lands as a start or as an
  # arrive-early buffer.
  describe "a leave time on something that does not exist yet" do
    let(:user) { create(:user) }
    let(:zone) { ActiveSupport::TimeZone["America/Denver"] }
    let(:now)  { zone.local(2026, 8, 3, 11, 4) }
    let(:tool) { Buddy::Tools[:add_agenda_item] }

    before {
      allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
      # Outside production AddressBook#traveltime_seconds answers 2700 flat, so
      # the drive is a fixed 45 minutes and the arithmetic is what is on trial.
      # Home only has to be findable; the chain has its own specs for choosing it.
      allow_any_instance_of(AgendaTravelChain::Resolver).to receive(:home)
        .and_return(Struct.new(:street).new("123 Home St"))
    }

    def ctx = Buddy::ToolContext.new(user)

    def leave!(payload)
      Timecop.freeze(now) {
        cast, errors = Buddy::Tools.validate_payload(tool, payload, zone: Buddy::Day.zone(user))
        raise errors.join("; ") if errors.any?

        confirm  = tool[:confirm].call(cast, ctx)
        resolved = cast.merge(confirm[:resolved] || {})
        tool[:guard]&.call(resolved, ctx)
        [resolved, confirm]
      }
    end

    def base(**extra)
      {
        title:    "Insidious Movie",
        leave_at: "2026-08-03T16:15:00",
        location: "Cinemark in Herriman",
        duration: 120,
        **extra,
      }
    end

    it "works the start back from the drive, leaving the unnamed buffer at their setting, and shows both on the row" do
      resolved, = leave!(base)
      label     = Timecop.freeze(now) { tool[:label].call(resolved, ctx) }

      # 4:15 out of the door + 45 minutes driving + the 5 they chose = 5:05.
      expect(resolved[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("5:05 PM")
      expect(resolved[:arrive_early]).to be_nil
      expect(label[:sub]).to include("leave 4:15pm", "5:05-7:05pm")
    end

    it "works back through a buffer they did name" do
      resolved, = leave!(base(arrive_early: 20))

      expect(resolved[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("5:20 PM")
    end

    it "writes that start to the row, and the leave time lands where they asked" do
      resolved, = leave!(base)
      item      = Timecop.freeze(now) { AgendaItem.find(tool[:execute].call(resolved, ctx)[:agenda_item_id]) }

      leave = item.start_at - item.arrive_early_minutes.minutes - 2700.seconds
      expect(leave.in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:15 PM")
    end

    it "refuses a start and a leave time in the same call" do
      expect { leave!(base(at: "2026-08-03T16:15:00")) }.to raise_error(/not both/)
    end

    # Refused rather than guessed, and refused BEFORE anything is created - once
    # the row exists there is nothing to do but let the leave time stand as a
    # start, which is the mistake the argument exists to stop.
    it "refuses a leave time with nowhere to drive to" do
      expect { leave!(base(location: nil)) }.to raise_error(/somewhere to drive/)
    end

    it "leaves a plain `at` alone" do
      resolved, = leave!({ title: "Insidious Movie", at: "2026-08-03T16:40:00", location: "Cinemark" })

      expect(resolved[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:40 PM")
      expect(resolved[:leave_from]).to be_nil
    end

    # AgendaTravelChain measures each leg from the PREVIOUS stop. The row does
    # not exist yet, so there is nothing to chain and the origin is worked out
    # here - the last place they are due to be before then, home otherwise.
    describe "where they are coming from" do
      it "takes the last place they are due to be that day" do
        user.agendas.first.agenda_items.create!(
          name:     "Lunch",
          kind:     :event,
          start_at: zone.local(2026, 8, 3, 12, 0),
          end_at:   zone.local(2026, 8, 3, 13, 0),
          location: "Lucky Ones",
        )

        expect(ctx.previous_stop_location(zone.local(2026, 8, 3, 16, 15))).to eq("Lucky Ones")
      end

      it "ignores one with nowhere to be, which is not a place they drove to" do
        user.agendas.first.agenda_items.create!(
          name:     "Read",
          kind:     :event,
          start_at: zone.local(2026, 8, 3, 12, 0),
          end_at:   zone.local(2026, 8, 3, 13, 0),
        )

        expect(ctx.previous_stop_location(zone.local(2026, 8, 3, 16, 15))).to be_nil
      end

      it "ignores one that has not happened yet" do
        user.agendas.first.agenda_items.create!(
          name:     "Dinner",
          kind:     :event,
          start_at: zone.local(2026, 8, 3, 19, 0),
          end_at:   zone.local(2026, 8, 3, 20, 0),
          location: "Home",
        )

        expect(ctx.previous_stop_location(zone.local(2026, 8, 3, 16, 15))).to be_nil
      end
    end
  end
end
