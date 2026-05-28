require "rails_helper"

# Focused coverage for the audit-followup behaviors:
#   * timestamp-based fast_skip (local edit vs Google's `updated`)
#   * excluded_dates merge on recurring-master upsert
#   * cancellation deferral when master is on a later page
#   * all-day event timezone interpretation
#   * trigger suppression / single tail broadcast during sync
RSpec.describe GoogleCalendar::Sync do
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
