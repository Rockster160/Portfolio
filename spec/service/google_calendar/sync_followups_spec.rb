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

  describe "trigger suppression during sync" do
    it "doesn't fire per-row Jil :agenda_item triggers" do
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
      expect(::Jil).not_to receive(:trigger).with(anything, :agenda_item, anything)

      described_class.new(agenda).run!
    end
  end
end
