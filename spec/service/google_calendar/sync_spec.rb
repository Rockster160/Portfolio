require "rails_helper"

RSpec.describe GoogleCalendar::Sync do
  describe "syncing" do
    let(:user) { create(:user) }
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "a@example.com", access_token: "t", refresh_token: "r")
    }
    let(:agenda) {
      create(
        :agenda, user: user, source: :google, external_id: "cal-abc",
        google_account: google_account, color: "#aabbcc"
      )
    }
    let(:api) { instance_double(Oauth::GoogleApi) }

    before do
      allow(Oauth::GoogleApi).to receive(:for_account).with(google_account).and_return(api)
      # ensure_timezone! pings calendarList lazily — stub it so tests don't
      # need to mock it individually. Returns nil = no-op.
      allow(api).to receive(:get_calendar).and_return(nil)
    end

    def page(items, sync_token: "next-token", next_page: nil)
      {
        items:         items,
        nextSyncToken: sync_token,
        nextPageToken: next_page,
      }.compact
    end

    describe "#run! — initial full sync" do
      it "passes time_min (not syncToken) when no token is cached" do
        allow(api).to receive(:list_events).with(
          agenda.external_id,
          time_min:   kind_of(ActiveSupport::TimeWithZone),
          page_token: nil,
        ).and_return(page([]))

        described_class.new(agenda).run!
        expect(agenda.reload.sync_token).to eq("next-token")
        expect(agenda.synced_at).to be_present
      end

      it "creates an AgendaSchedule for a recurring master" do
        event = {
          id:          "evt-master-1",
          status:      "confirmed",
          summary:     "Standup",
          location:    "Zoom",
          description: "Daily sync",
          start:       { dateTime: "2026-05-22T09:00:00-04:00" },
          end:         { dateTime: "2026-05-22T09:30:00-04:00" },
          recurrence:  ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"],
          etag:        %("etag-1"),
          updated:     "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        sched = agenda.agenda_schedules.find_by(external_uid: "evt-master-1")
        expect(sched).to be_present
        expect(sched.name).to eq("Standup")
        expect(sched.kind).to eq("event")
        expect(sched.recurrence["freq"]).to eq("weekly")
        expect(sched.recurrence["by_day"]).to match_array(%w[mon wed fri])
        expect(sched.duration_minutes).to eq(30)
        expect(sched.external_etag).to eq(%("etag-1"))
      end

      it "creates an AgendaItem for a one-off event" do
        event = {
          id:       "evt-oneoff-1",
          status:   "confirmed",
          summary:  "Dentist",
          location: "5th Ave",
          start:    { dateTime: "2026-05-23T14:00:00-04:00" },
          end:      { dateTime: "2026-05-23T15:00:00-04:00" },
          etag:     %("etag-2"),
          updated:  "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-oneoff-1")
        expect(item).to be_present
        expect(item.kind).to eq("event")
        expect(item.location).to eq("5th Ave")
      end

      it "creates a detached AgendaItem for a recurringEventId override" do
        master = agenda.agenda_schedules.create!(
          name: "Standup", kind: :event, start_time: "09:00",
          duration_minutes: 30, starts_on: Date.current,
          recurrence: { "freq" => "daily" },
          external_uid: "evt-master-1"
        )
        override_event = {
          id:                "evt-master-1_20260525T130000Z",
          status:            "confirmed",
          summary:           "Standup (rescheduled)",
          recurringEventId:  "evt-master-1",
          originalStartTime: { dateTime: "2026-05-25T09:00:00-04:00" },
          start:             { dateTime: "2026-05-25T13:00:00-04:00" },
          end:               { dateTime: "2026-05-25T13:30:00-04:00" },
          etag:              %("etag-3"),
          updated:           "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([override_event]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-master-1_20260525T130000Z")
        expect(item).to be_present
        expect(item.agenda_schedule_id).to eq(master.id)
        expect(item.detached_at).to be_present
        expect(item.original_start_at).to be_present
        expect(item.name).to eq("Standup (rescheduled)")
      end

      it "excludes the original date on the master so the phantom + override don't both render" do
        master = agenda.agenda_schedules.create!(
          name: "Standup", kind: :event, start_time: "09:00",
          duration_minutes: 30, starts_on: Date.new(2026, 5, 1),
          recurrence: { "freq" => "daily" },
          external_uid: "evt-master-2"
        )
        override_event = {
          id:                "evt-master-2_20260525T130000Z",
          status:            "confirmed",
          summary:           "Standup (moved)",
          recurringEventId:  "evt-master-2",
          originalStartTime: { dateTime: "2026-05-25T09:00:00-04:00" },
          start:             { dateTime: "2026-05-25T13:00:00-04:00" },
          end:               { dateTime: "2026-05-25T13:30:00-04:00" },
          etag:              %("etag-3a"),
          updated:           "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([override_event]))

        described_class.new(agenda).run!
        master.reload
        original_date = Time.zone.parse("2026-05-25T09:00:00-04:00").in_time_zone(user.timezone).to_date
        expect(master.excluded_dates).to include(original_date)
        # And the items rendered for that day should only be the override, not
        # also the phantom that the schedule would otherwise emit.
        items = agenda.items_for(original_date)
        expect(items.size).to eq(1)
        expect(items.first.external_uid).to eq("evt-master-2_20260525T130000Z")
      end

      it "claims a locally-materialized phantom row instead of creating a duplicate override" do
        master = agenda.agenda_schedules.create!(
          name: "Standup", kind: :event, start_time: "09:00",
          duration_minutes: 30, starts_on: Date.new(2026, 5, 1),
          recurrence: { "freq" => "daily" },
          external_uid: "evt-master-3"
        )
        occurrence_date = Time.zone.parse("2026-05-25T09:00:00-04:00").in_time_zone(user.timezone).to_date
        occ_start = ActiveSupport::TimeZone[user.timezone].local(
          occurrence_date.year, occurrence_date.month, occurrence_date.day, 9, 0
        )
        pre_materialized = master.agenda_items.create!(
          agenda:      agenda,
          kind:        :event,
          name:        "Standup",
          start_at:    occ_start,
          end_at:      occ_start + 30.minutes,
          notified_at: 10.minutes.ago,
        )
        override_event = {
          id:                "evt-master-3_20260525T130000Z",
          status:            "confirmed",
          summary:           "Standup (rescheduled)",
          recurringEventId:  "evt-master-3",
          originalStartTime: { dateTime: "2026-05-25T09:00:00-04:00" },
          start:             { dateTime: "2026-05-25T13:00:00-04:00" },
          end:               { dateTime: "2026-05-25T13:30:00-04:00" },
          etag:              %("etag-3b"),
          updated:           "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([override_event]))

        expect { described_class.new(agenda).run! }.not_to change(AgendaItem, :count)
        pre_materialized.reload
        expect(pre_materialized.external_uid).to eq("evt-master-3_20260525T130000Z")
        expect(pre_materialized.detached_at).to be_present
        expect(pre_materialized.notified_at).to be_present
        expect(pre_materialized.name).to eq("Standup (rescheduled)")
      end

      it "ignores an override whose master hasn't synced yet (handled on next pass)" do
        override_event = {
          id:               "evt-master-x_20260525T130000Z",
          status:           "confirmed",
          recurringEventId: "evt-master-x",
          start:            { dateTime: "2026-05-25T13:00:00-04:00" },
          end:              { dateTime: "2026-05-25T13:30:00-04:00" },
          etag:             %("etag-4"),
          updated:          "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([override_event]))

        expect { described_class.new(agenda).run! }.not_to change(AgendaItem, :count)
      end

      it "destroys a record when status=cancelled arrives" do
        item = agenda.agenda_items.create!(
          name: "Old", kind: :event, start_at: 1.day.from_now,
          end_at: 1.day.from_now + 1.hour, external_uid: "evt-gone-1"
        )
        cancelled = { id: "evt-gone-1", status: "cancelled" }
        allow(api).to receive(:list_events).and_return(page([cancelled]))

        described_class.new(agenda).run!
        expect(AgendaItem.exists?(item.id)).to be(false)
      end

      it "skips an item the user has locally edited (locally_modified_at present)" do
        item = agenda.agenda_items.create!(
          name: "User's name", kind: :event, start_at: 1.day.from_now,
          end_at: 1.day.from_now + 1.hour,
          external_uid: "evt-locked-1", external_etag: %("etag-old"),
          locally_modified_at: 1.minute.ago
        )
        event = {
          id:      "evt-locked-1",
          status:  "confirmed",
          summary: "Google's new name",
          start:   { dateTime: "2026-05-25T09:00:00-04:00" },
          end:     { dateTime: "2026-05-25T10:00:00-04:00" },
          etag:    %("etag-new"),
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        expect(item.reload.name).to eq("User's name")
      end

      it "fast-skips an unchanged event (same etag)" do
        etag = %("etag-stable")
        item = agenda.agenda_items.create!(
          name: "Original", kind: :event, start_at: 1.day.from_now,
          end_at: 1.day.from_now + 1.hour,
          external_uid: "evt-stable-1", external_etag: etag
        )
        event = {
          id:      "evt-stable-1",
          status:  "confirmed",
          summary: "DIFFERENT — should be ignored due to etag match",
          start:   { dateTime: "2026-05-25T09:00:00-04:00" },
          end:     { dateTime: "2026-05-25T10:00:00-04:00" },
          etag:    etag,
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        expect(item.reload.name).to eq("Original")
      end

      it "paginates via nextPageToken" do
        first = page([], sync_token: nil, next_page: "page-2")
        second = page([])
        allow(api).to receive(:list_events).with(
          agenda.external_id, time_min: kind_of(ActiveSupport::TimeWithZone), page_token: nil
        ).and_return(first)
        allow(api).to receive(:list_events).with(
          agenda.external_id, time_min: kind_of(ActiveSupport::TimeWithZone), page_token: "page-2"
        ).and_return(second)

        described_class.new(agenda).run!
        expect(api).to have_received(:list_events).twice
      end
    end

    describe "#run! — incremental sync" do
      it "passes syncToken (not time_min) when one is cached" do
        agenda.update!(sync_token: "stored-token")
        allow(api).to receive(:list_events).with(
          agenda.external_id, sync_token: "stored-token", page_token: nil
        ).and_return(page([], sync_token: "newer-token"))

        described_class.new(agenda).run!
        expect(agenda.reload.sync_token).to eq("newer-token")
      end

      it "re-bootstraps with a full sync when the sync_token returns 410 Gone" do
        agenda.update!(sync_token: "expired-token")
        gone = RestClient::Gone.new(instance_double(RestClient::Response, code: 410, body: "{}"))
        call_count = 0
        allow(api).to receive(:list_events) { |*_args, **_kwargs|
          call_count += 1
          call_count == 1 ? raise(gone) : page([], sync_token: "fresh-token")
        }

        described_class.new(agenda).run!
        expect(agenda.reload.sync_token).to eq("fresh-token")
      end

      it "guards against repeated 410 Gone loops" do
        agenda.update!(sync_token: "expired-token")
        gone = RestClient::Gone.new(instance_double(RestClient::Response, code: 410, body: "{}"))
        allow(api).to receive(:list_events).and_raise(gone)

        expect { described_class.new(agenda).run! }.not_to raise_error
      end
    end

    describe "all-day events" do
      let(:all_day_event) {
        {
          id:      "evt-allday-1",
          status:  "confirmed",
          summary: "Birthday",
          start:   { date: "2026-07-10" },
          end:     { date: "2026-07-11" },
          etag:    %("etag-a"),
          updated: "2026-05-22T08:00:00Z",
        }
      }

      it "imports a one-off all-day event with all_day=true" do
        allow(api).to receive(:list_events).and_return(page([all_day_event]))
        described_class.new(agenda).run!

        item = agenda.agenda_items.find_by(external_uid: "evt-allday-1")
        expect(item).to be_present
        expect(item.all_day).to be(true)
        expect(item.kind).to eq("event")
      end

      it "imports a recurring all-day master with all_day=true" do
        master = all_day_event.merge(recurrence: ["RRULE:FREQ=YEARLY"])
        allow(api).to receive(:list_events).and_return(page([master]))
        described_class.new(agenda).run!

        sched = agenda.agenda_schedules.find_by(external_uid: "evt-allday-1")
        expect(sched).to be_present
        expect(sched.all_day).to be(true)
        expect(sched.duration_minutes).to eq(24 * 60)
        expect(sched.start_time.strftime("%H:%M")).to eq("00:00")
      end
    end

    # Regression: upsert_schedule writes `start_time` as a wall-clock HH:MM
    # for the phantom builder, which interprets it in the USER's zone. Pre-fix
    # we wrote it in the EVENT's source zone (Google's `timeZone` field), so
    # phantoms for any master authored in a non-user zone projected an hour
    # (or more) off — visible on the agenda as the wrong time-of-day.
    describe "schedule start_time is stored in the user's timezone" do
      it "writes start_time in user-local even when the event's timeZone is different" do
        master = {
          id:         "evt-master-tz",
          status:     "confirmed",
          summary:    "Tech Roundtable",
          # 11:00 Central time = 10:00 Mountain time. Pre-fix stored "11:00".
          start:      { dateTime: "2026-04-29T11:00:00", timeZone: "America/Chicago" },
          end:        { dateTime: "2026-04-29T11:30:00", timeZone: "America/Chicago" },
          recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=WE;INTERVAL=2"],
          etag:       %("etag-tz"),
          updated:    "2026-04-29T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([master]))

        described_class.new(agenda).run!
        sched = agenda.agenda_schedules.find_by(external_uid: "evt-master-tz")
        expect(sched).to be_present
        expect(sched.start_time.strftime("%H:%M")).to eq("10:00")
        expect(sched.starts_on).to eq(Date.new(2026, 4, 29))

        # And the phantom rendered for a future occurrence projects at the
        # user-local time, not the source zone's time.
        phantom_at = sched.occurrence_start_at(Date.new(2026, 5, 13))
        expect(phantom_at.in_time_zone(agenda.user.timezone).strftime("%H:%M")).to eq("10:00")
      end

      it "leaves start_time as 00:00 for all-day events (no TZ ambiguity)" do
        allday = {
          id:         "evt-allday-tz",
          status:     "confirmed",
          summary:    "Birthday",
          start:      { date: "2026-07-10" },
          end:        { date: "2026-07-11" },
          recurrence: ["RRULE:FREQ=YEARLY"],
          etag:       %("etag-allday"),
          updated:    "2026-04-29T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([allday]))

        described_class.new(agenda).run!
        sched = agenda.agenda_schedules.find_by(external_uid: "evt-allday-tz")
        expect(sched.start_time.strftime("%H:%M")).to eq("00:00")
        expect(sched.starts_on).to eq(Date.new(2026, 7, 10))
      end

      it "is a no-op when the event's timeZone already matches the user's zone" do
        master = {
          id:         "evt-master-tz-match",
          status:     "confirmed",
          summary:    "Standup",
          start:      { dateTime: "2026-04-29T10:30:00", timeZone: "America/Denver" },
          end:        { dateTime: "2026-04-29T11:00:00", timeZone: "America/Denver" },
          recurrence: ["RRULE:FREQ=DAILY"],
          etag:       %("etag-tz-match"),
          updated:    "2026-04-29T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([master]))

        described_class.new(agenda).run!
        sched = agenda.agenda_schedules.find_by(external_uid: "evt-master-tz-match")
        expect(sched.start_time.strftime("%H:%M")).to eq("10:30")
      end
    end

    describe "two-pass page ordering" do
      it "applies recurring masters before overrides within the same page" do
        master = {
          id:         "evt-m",
          status:     "confirmed",
          summary:    "Standup",
          start:      { dateTime: "2026-05-22T09:00:00-04:00" },
          end:        { dateTime: "2026-05-22T09:30:00-04:00" },
          recurrence: ["RRULE:FREQ=DAILY"],
          etag:       %("e1"),
          updated:    "2026-05-22T08:00:00Z",
        }
        override = {
          id:                "evt-m_20260525T130000Z",
          status:            "confirmed",
          summary:           "Standup (moved)",
          recurringEventId:  "evt-m",
          originalStartTime: { dateTime: "2026-05-25T09:00:00-04:00" },
          start:             { dateTime: "2026-05-25T13:00:00-04:00" },
          end:               { dateTime: "2026-05-25T13:30:00-04:00" },
          etag:              %("e2"),
          updated:           "2026-05-22T08:00:00Z",
        }
        # Override listed FIRST in the page — Sync should still resolve master first.
        allow(api).to receive(:list_events).and_return(page([override, master]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-m_20260525T130000Z")
        expect(item).to be_present
        expect(item.agenda_schedule_id).to eq(
          agenda.agenda_schedules.find_by(external_uid: "evt-m").id,
        )
      end
    end

    describe "attendees + response state" do
      it "persists declined invites with self_response in metadata" do
        declined = {
          id:        "evt-decline-1",
          status:    "confirmed",
          summary:   "Optional meeting",
          start:     { dateTime: "2026-05-23T14:00:00-04:00" },
          end:       { dateTime: "2026-05-23T15:00:00-04:00" },
          attendees: [
            { email: "me@example.com", self: true, responseStatus: "declined" },
            { email: "other@example.com", responseStatus: "accepted" },
          ],
          etag:      %("e3"),
          updated:   "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([declined]))

        expect { described_class.new(agenda).run! }.to change(AgendaItem, :count).by(1)
        item = agenda.agenda_items.find_by(external_uid: "evt-decline-1")
        expect(item.self_response).to eq("declined")
        expect(item.declined?).to be true
        expect(item.attendees.size).to eq(2)
        expect(item.status).to eq("confirmed")
      end

      it "marks needsAction invites with the badge metadata" do
        pending_event = {
          id:        "evt-pending-1",
          status:    "confirmed",
          summary:   "Pending invite",
          start:     { dateTime: "2026-05-23T14:00:00-04:00" },
          end:       { dateTime: "2026-05-23T15:00:00-04:00" },
          attendees: [
            { email: "me@example.com", self: true, responseStatus: "needsAction" },
          ],
          organizer: { email: "boss@example.com", displayName: "Boss" },
          etag:      %("e3a"),
          updated:   "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([pending_event]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-pending-1")
        expect(item.needs_response?).to be true
        expect(item.self_response).to eq("needsAction")
        expect(item.organizer["email"]).to eq("boss@example.com")
      end

      it "keeps :tentative status for tentative responses" do
        tentative = {
          id:        "evt-tent-1",
          status:    "confirmed",
          summary:   "Maybe meeting",
          start:     { dateTime: "2026-05-23T14:00:00-04:00" },
          end:       { dateTime: "2026-05-23T15:00:00-04:00" },
          attendees: [
            { email: "me@example.com", self: true, responseStatus: "tentative" },
          ],
          etag:      %("e3b"),
          updated:   "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([tentative]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-tent-1")
        expect(item.status).to eq("tentative")
        expect(item.self_response).to eq("tentative")
      end
    end

    describe "color + html + conferenceData" do
      it "maps event colorId to hex" do
        event = {
          id:      "evt-color-1",
          status:  "confirmed",
          summary: "Red",
          colorId: "11",
          start:   { dateTime: "2026-05-23T14:00:00-04:00" },
          end:     { dateTime: "2026-05-23T15:00:00-04:00" },
          etag:    %("e4"),
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        expect(agenda.agenda_items.find_by(external_uid: "evt-color-1").color).to eq("#dc2127")
      end

      it "strips HTML from description before storing" do
        event = {
          id:          "evt-html-1",
          status:      "confirmed",
          summary:     "Notes",
          description: "<p>Bring <strong>laptop</strong> &amp; charger</p>",
          start:       { dateTime: "2026-05-23T14:00:00-04:00" },
          end:         { dateTime: "2026-05-23T15:00:00-04:00" },
          etag:        %("e5"),
          updated:     "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        expect(agenda.agenda_items.find_by(external_uid: "evt-html-1").notes).to eq("Bring laptop & charger")
      end

      it "uses Meet/Zoom link from conferenceData when no explicit location" do
        event = {
          id:             "evt-conf-1",
          status:         "confirmed",
          summary:        "Sync",
          start:          { dateTime: "2026-05-23T14:00:00-04:00" },
          end:            { dateTime: "2026-05-23T15:00:00-04:00" },
          conferenceData: {
            entryPoints: [{ entryPointType: "video", uri: "https://meet.google.com/abc-defg-hij" }],
          },
          etag:           %("e6"),
          updated:        "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-conf-1")
        expect(item.location).to eq("https://meet.google.com/abc-defg-hij")
      end
    end

    describe "rule we can't represent" do
      it "skips events with HOURLY recurrence (no schedule created)" do
        event = {
          id:         "evt-hourly-1",
          status:     "confirmed",
          summary:    "Ping",
          start:      { dateTime: "2026-05-23T14:00:00-04:00" },
          end:        { dateTime: "2026-05-23T15:00:00-04:00" },
          recurrence: ["RRULE:FREQ=HOURLY;INTERVAL=2"],
          etag:       %("e7"),
          updated:    "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        expect { described_class.new(agenda).run! }.not_to change(AgendaSchedule, :count)
      end
    end

    describe "OAuth token revoked" do
      it "marks the GoogleAccount as needing reauth on Unauthorized" do
        allow(api).to receive(:list_events).and_raise(
          RestClient::Unauthorized.new(instance_double(RestClient::Response, code: 401, body: "")),
        )

        result = described_class.new(agenda).run!
        expect(result).to eq(:reauth_required)
        expect(google_account.reload.reauth_required_at).to be_present
      end

      it "clears reauth_required_at on a successful sync" do
        google_account.update!(reauth_required_at: 1.day.ago)
        allow(api).to receive(:list_events).and_return(page([]))

        described_class.new(agenda).run!
        expect(google_account.reload.reauth_required_at).to be_nil
      end
    end

    # `add_excluded_date!` states the invariant in as many words: a date in
    # excluded_dates means no occurrence on that date, and it sweeps any row
    # already materialized there. This writer doesn't go through it — it merges
    # the master's inbound EXDATEs into `recurrence` and calls save! — so the
    # sweep never ran on this path and a row we'd written ahead of time survived
    # as an instance of a series that no longer had one.
    describe "an EXDATE arriving on a recurring master" do
      let(:excluded_on) { Date.new(2026, 6, 1) }

      def master_event(exdates, etag: "etag-1")
        recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO"]
        recurrence << "EXDATE:#{exdates.map { |d| d.strftime("%Y%m%d") }.join(",")}" if exdates.any?
        {
          id:         "evt-series-1",
          status:     "confirmed",
          summary:    "Tech Stand-Up",
          start:      { dateTime: "2026-05-25T09:30:00-06:00" },
          end:        { dateTime: "2026-05-25T10:00:00-06:00" },
          recurrence: recurrence,
          etag:       %("#{etag}"),
          updated:    "2026-05-22T08:00:00Z",
        }
      end

      def sync!(event)
        allow(api).to receive(:list_events).and_return(page([event]))
        described_class.new(agenda).run!
      end

      def materialized_on(date, schedule, detached: nil)
        zone = ActiveSupport::TimeZone[agenda.user.timezone] || Time.zone
        at   = zone.local(date.year, date.month, date.day, 9, 30)
        agenda.agenda_items.create!(
          name: "Tech Stand-Up", kind: :event, start_at: at, end_at: at + 30.minutes,
          agenda_schedule: schedule, detached_at: detached
        )
      end

      it "cancels a row already materialized on the newly excluded date" do
        sync!(master_event([]))
        schedule = agenda.agenda_schedules.find_by(external_uid: "evt-series-1")
        item = materialized_on(excluded_on, schedule)

        sync!(master_event([excluded_on], etag: "etag-2"))

        expect(schedule.reload.excluded_dates).to include(excluded_on)
        expect(item.reload.status).to eq("cancelled")
      end

      # The ordinary Google shape for a MOVED occurrence: an EXDATE on the master
      # plus its own detached event. Cancelling that row would delete the meeting
      # rather than the ghost — which is why the sweep skips detached overrides,
      # and why this has to keep skipping them here.
      it "leaves a detached override on that date alone" do
        sync!(master_event([]))
        schedule = agenda.agenda_schedules.find_by(external_uid: "evt-series-1")
        override = materialized_on(excluded_on, schedule, detached: Time.current)

        sync!(master_event([excluded_on], etag: "etag-2"))

        expect(override.reload.status).to eq("confirmed")
      end

      it "leaves rows on dates the series still has" do
        sync!(master_event([]))
        schedule = agenda.agenda_schedules.find_by(external_uid: "evt-series-1")
        kept = materialized_on(excluded_on + 7, schedule)

        sync!(master_event([excluded_on], etag: "etag-2"))

        expect(kept.reload.status).to eq("confirmed")
      end

      # A resync carrying the same EXDATE it already knew about must not re-sweep:
      # a row legitimately re-created on that date later is not this method's to
      # cancel, and re-running a sync is not a user action.
      it "only sweeps dates it hasn't already seen" do
        sync!(master_event([excluded_on]))
        schedule = agenda.agenda_schedules.find_by(external_uid: "evt-series-1")
        later = materialized_on(excluded_on, schedule)

        sync!(master_event([excluded_on], etag: "etag-3"))

        expect(later.reload.status).to eq("confirmed")
      end
    end
  end

  # Focused coverage for the audit-followup behaviors:
  #   * timestamp-based fast_skip (local edit vs Google's `updated`)
  #   * excluded_dates merge on recurring-master upsert
  #   * cancellation deferral when master is on a later page
  #   * all-day event timezone interpretation
  #   * trigger suppression / single tail broadcast during sync
  describe "followups" do
    let(:user) {
      u = create(:user)
      allow(u).to receive(:timezone).and_return("America/Los_Angeles")
      u
    }
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "tz@example.com", access_token: "t", refresh_token: "r")
    }
    let(:agenda) {
      create(
        :agenda, user: user, source: :google, external_id: "cal-tz",
        google_account: google_account, color: "#aabbcc"
      )
    }
    let(:api) { instance_double(Oauth::GoogleApi) }

    before do
      allow(Oauth::GoogleApi).to receive(:for_account).with(google_account).and_return(api)
      allow(api).to receive(:get_calendar).and_return({ timeZone: "America/Los_Angeles" })
    end

    def page(items, sync_token: "next-token", next_page: nil)
      { items: items, nextSyncToken: sync_token, nextPageToken: next_page }.compact
    end

    describe "timed event with no offset in dateTime + explicit timeZone field" do
      it "interprets the dateTime in the event's timeZone field (NOT as UTC)" do
        # Google may omit the UTC offset from `dateTime` when an explicit
        # `timeZone` is set. Bare Time.zone.parse in a Sidekiq worker
        # (Time.zone = UTC) would mis-interpret this as UTC → 9am Denver
        # display for an intended 3pm Denver event.
        event = {
          id:      "evt-tz-explicit",
          status:  "confirmed",
          summary: "3pm meeting",
          start:   { dateTime: "2026-05-28T15:00:00", timeZone: "America/Denver" },
          end:     { dateTime: "2026-05-28T15:30:00", timeZone: "America/Denver" },
          etag:    %("tz1"),
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-tz-explicit")
        expect(item).to be_present
        # 15:00 Denver MDT = 21:00 UTC, and the test user is in
        # America/Los_Angeles (UTC-7 in May), so the rendered hour is 14:00.
        # The crucial assertion: it's the SAME instant as "3pm Denver",
        # not 9am Denver (which is what bare Time.zone.parse would yield).
        expect(item.start_at.in_time_zone("America/Denver").strftime("%H:%M")).to eq("15:00")
        expect(item.end_at.in_time_zone("America/Denver").strftime("%H:%M")).to eq("15:30")
      end

      it "still honors an explicit offset in dateTime when one is present" do
        event = {
          id:      "evt-tz-offset",
          status:  "confirmed",
          summary: "3pm meeting w/ offset",
          start:   { dateTime: "2026-05-28T15:00:00-06:00" },
          end:     { dateTime: "2026-05-28T15:30:00-06:00" },
          etag:    %("tz2"),
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-tz-offset")
        expect(item.start_at.in_time_zone("America/Denver").strftime("%H:%M")).to eq("15:00")
      end
    end

    describe "all-day TZ interpretation" do
      it "stores start_at as midnight in the user's timezone (PST)" do
        event = {
          id:      "evt-allday-2",
          status:  "confirmed",
          summary: "Vacation day",
          start:   { date: "2026-05-28" },
          end:     { date: "2026-05-29" },
          etag:    %("e1"),
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-allday-2")
        # The whole point: regardless of worker-process Time.zone, the user
        # should see this all-day event on May 28.
        expect(item.start_at.in_time_zone(user.timezone).to_date).to eq(Date.new(2026, 5, 28))
        expect(item.end_at.in_time_zone(user.timezone).to_date).to eq(Date.new(2026, 5, 29))
      end
    end

    describe "fast_skip timestamp comparison" do
      let(:event) {
        {
          id:      "evt-edit-1",
          status:  "confirmed",
          summary: "Renamed remotely",
          start:   { dateTime: "2026-05-23T14:00:00-04:00" },
          end:     { dateTime: "2026-05-23T15:00:00-04:00" },
          etag:    %("etag-fresh"),
          updated: "2026-05-22T10:00:00Z",
        }
      }

      it "skips the row when our local edit is newer than Google's updated" do
        AgendaItem.create!(
          agenda:              agenda,
          kind:                :event,
          name:                "My local edit",
          start_at:            Time.zone.parse("2026-05-23T14:00:00-04:00"),
          end_at:              Time.zone.parse("2026-05-23T15:00:00-04:00"),
          external_uid:        "evt-edit-1",
          external_etag:       %("etag-old"),
          external_updated_at: Time.zone.parse("2026-05-22T09:00:00Z"),
          locally_modified_at: Time.zone.parse("2026-05-22T11:00:00Z"),
        )
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        expect(agenda.agenda_items.find_by(external_uid: "evt-edit-1").name).to eq("My local edit")
      end

      it "applies Google's version AND clears locally_modified_at when Google is newer" do
        AgendaItem.create!(
          agenda:              agenda,
          kind:                :event,
          name:                "My local edit",
          start_at:            Time.zone.parse("2026-05-23T14:00:00-04:00"),
          end_at:              Time.zone.parse("2026-05-23T15:00:00-04:00"),
          external_uid:        "evt-edit-1",
          external_etag:       %("etag-old"),
          external_updated_at: Time.zone.parse("2026-05-22T08:00:00Z"),
          locally_modified_at: Time.zone.parse("2026-05-22T09:00:00Z"),
        )
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        item = agenda.agenda_items.find_by(external_uid: "evt-edit-1")
        expect(item.name).to eq("Renamed remotely")
        expect(item.locally_modified_at).to be_nil
      end
    end

    describe "excluded_dates merge" do
      it "preserves locally-recorded excluded_dates when Google PATCHes the master" do
        existing = AgendaSchedule.create!(
          agenda:           agenda,
          kind:             :event,
          name:             "Standup",
          start_time:       "09:00",
          starts_on:        Date.new(2026, 5, 1),
          duration_minutes: 30,
          external_uid:     "evt-master-merge",
          external_etag:    %("e-old"),
          recurrence:       {
            freq:           "daily",
            excluded_dates: ["2026-05-10"],
          },
        )

        event = {
          id:          "evt-master-merge",
          status:      "confirmed",
          summary:     "Standup (renamed)",
          start:       { dateTime: "2026-05-01T09:00:00-04:00" },
          end:         { dateTime: "2026-05-01T09:30:00-04:00" },
          recurrence:  ["RRULE:FREQ=DAILY"],
          etag:        %("e-new"),
          updated:     "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))

        described_class.new(agenda).run!
        reloaded = existing.reload
        expect(reloaded.name).to eq("Standup (renamed)")
        expect(reloaded.excluded_dates.map(&:to_s)).to include("2026-05-10")
      end
    end

    describe "cancellation deferral" do
      it "deferred-applies a single-occurrence cancellation whose master is on a later page" do
        # Page 1: cancellation referencing not-yet-seen master.
        page1 = {
          items:         [
            {
              id:                "evt-m-c_20260520T130000Z",
              status:            "cancelled",
              recurringEventId:  "evt-m-c",
              originalStartTime: { dateTime: "2026-05-20T09:00:00-04:00" },
            },
          ],
          nextPageToken: "p2",
        }
        page2 = page([
          {
            id:         "evt-m-c",
            status:     "confirmed",
            summary:    "Standup",
            start:      { dateTime: "2026-05-20T09:00:00-04:00" },
            end:        { dateTime: "2026-05-20T09:30:00-04:00" },
            recurrence: ["RRULE:FREQ=DAILY"],
            etag:       %("e1"),
            updated:    "2026-05-22T08:00:00Z",
          },
        ])
        allow(api).to receive(:list_events).and_return(page1, page2)

        described_class.new(agenda).run!
        master = agenda.agenda_schedules.find_by(external_uid: "evt-m-c")
        expect(master).to be_present
        expect(master.excluded_dates.map(&:to_s)).to include("2026-05-20")
      end
    end

    describe "one bad event doesn't wedge the sync" do
      it "skips a zero-duration event (end_at == start_at) and continues with the others, padding end_at out so the row still imports" do
        zero_dur = {
          id:      "evt-zero-dur",
          status:  "confirmed",
          summary: "Bad event",
          start:   { dateTime: "2026-05-23T14:00:00-04:00" },
          end:     { dateTime: "2026-05-23T14:00:00-04:00" }, # zero duration
          etag:    %("zero1"),
          updated: "2026-05-22T08:00:00Z",
        }
        good = {
          id:      "evt-good",
          status:  "confirmed",
          summary: "Good event",
          start:   { dateTime: "2026-05-23T15:00:00-04:00" },
          end:     { dateTime: "2026-05-23T16:00:00-04:00" },
          etag:    %("g1"),
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([zero_dur, good]))

        described_class.new(agenda).run!
        # Good event still imports.
        expect(agenda.agenda_items.find_by(external_uid: "evt-good")).to be_present
        # Zero-dur event ALSO imports (we pad end_at by 30 min).
        bad_item = agenda.agenda_items.find_by(external_uid: "evt-zero-dur")
        expect(bad_item).to be_present
        expect(bad_item.end_at).to be > bad_item.start_at
        # synced_at is set (sync didn't wedge).
        expect(agenda.reload.synced_at).to be_present
      end

      it "even if a row raises RecordInvalid for some other reason, the sync continues" do
        crashy = {
          id:      "evt-crash",
          status:  "confirmed",
          summary: "Crashes",
          # Force an invalid row Google could plausibly send: summary blank
          # makes `event_summary` fall back to "(no title)" which is fine —
          # so we trigger via the name validation a different way: empty
          # name override via a stub on assign_attributes for that one row.
          start:   { dateTime: "2026-05-23T14:00:00-04:00" },
          end:     { dateTime: "2026-05-23T15:00:00-04:00" },
          etag:    %("c1"),
          updated: "2026-05-22T08:00:00Z",
        }
        good = {
          id:      "evt-after-crash",
          status:  "confirmed",
          summary: "After",
          start:   { dateTime: "2026-05-23T16:00:00-04:00" },
          end:     { dateTime: "2026-05-23T17:00:00-04:00" },
          etag:    %("a1"),
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([crashy, good]))
        # First save! raises a RecordInvalid; subsequent saves pass through.
        saves_seen = 0
        allow_any_instance_of(AgendaItem).to receive(:save!).and_wrap_original do |orig|
          saves_seen += 1
          if saves_seen == 1
            raise ActiveRecord::RecordInvalid.new(AgendaItem.new.tap { |i| i.errors.add(:base, "boom") })
          else
            orig.call
          end
        end

        described_class.new(agenda).run!
        expect(agenda.agenda_items.find_by(external_uid: "evt-after-crash")).to be_present
        expect(agenda.reload.synced_at).to be_present
      end
    end

    describe "trigger suppression during sync" do
      it "doesn't fire per-row Jil :agenda_item triggers (but DOES fire one :agenda_sync at the tail)" do
        event = {
          id:      "evt-bulk-1",
          status:  "confirmed",
          summary: "One of many",
          start:   { dateTime: "2026-05-23T14:00:00-04:00" },
          end:     { dateTime: "2026-05-23T15:00:00-04:00" },
          etag:    %("e1"),
          updated: "2026-05-22T08:00:00Z",
        }
        allow(api).to receive(:list_events).and_return(page([event]))
        triggered_scopes = []
        # rspec-mocks' verify_partial_doubles trips on Ruby 3 kwargs
        # separation when the method signature mixes positional + keyword
        # args. Patch the underlying executor instead — same observation,
        # without the verifier's strict-kwargs intercept.
        allow(::Jil::Executor).to receive(:trigger) { |_u, scope, _d, **_kw| triggered_scopes << scope }

        described_class.new(agenda).run!
        expect(triggered_scopes).not_to include(:agenda_item)
        expect(triggered_scopes).to include(:agenda_sync)
      end
    end
  end
end
