require "rails_helper"

RSpec.describe GoogleCalendar::Sync do
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

  describe "declined invites" do
    it "skips events the connected user has declined" do
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

      expect { described_class.new(agenda).run! }.not_to change(AgendaItem, :count)
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
end
