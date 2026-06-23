require "rails_helper"

RSpec.describe AgendaItem do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }

  describe "kind enum" do
    it "is integer-backed (not strings — strings waste storage + index space)" do
      expect(AgendaItem.columns_hash["kind"].type).to eq(:integer)
      expect(AgendaItem.kinds).to eq("task" => 0, "event" => 1, "trigger" => 2)
    end
  end

  describe "validations" do
    it "requires end_at for event kind" do
      item = build(:agenda_item, agenda: agenda, kind: "event", end_at: nil)
      expect(item).not_to be_valid
    end

    it "end_at must be after start_at" do
      now = Time.current
      item = build(:agenda_item, agenda: agenda, kind: "event", start_at: now, end_at: now)
      expect(item).not_to be_valid
    end
  end

  describe "#crossed_out?" do
    let(:now) { Time.zone.local(2026, 5, 13, 12, 0) }

    it "task crossed out when completed_at present" do
      item = create(:agenda_item, agenda: agenda, kind: "task",
        start_at: now - 2.hours, completed_at: now - 1.hour)
      expect(item.crossed_out?(now: now)).to be true
    end

    it "event crossed out after end_at passes" do
      item = create(:agenda_item, agenda: agenda, kind: "event",
        start_at: now - 2.hours, end_at: now - 1.hour)
      expect(item.crossed_out?(now: now)).to be true
    end
  end

  describe "phantom support" do
    let(:sched) {
      create(:agenda_schedule, agenda: agenda, kind: "task",
        recurrence: { "freq" => "daily" }, starts_on: Date.current)
    }

    it "phantoms expose a stable phantom_id with schedule + date" do
      date = Date.current + 5.days
      item = sched.phantom_for(date)
      expect(item.display_id).to eq("p-#{sched.id}-#{date.iso8601}")
    end

    it "materialize! converts a phantom into a real row" do
      date = Date.current + 5.days
      item = sched.phantom_for(date)
      expect { item.materialize! }.to change(AgendaItem, :count).by(1)
      expect(item).to be_persisted
      expect(item).not_to be_phantom
    end

    it "AgendaItem.locate resolves a phantom_id" do
      date = Date.current + 7.days
      phantom_id = "p-#{sched.id}-#{date.iso8601}"
      item = described_class.locate(phantom_id, agenda: agenda)
      expect(item).to be_phantom
      expect(item.agenda_schedule_id).to eq(sched.id)
    end

    it "AgendaItem.locate returns the real row if a phantom_id has already been materialized" do
      date = Date.current + 7.days
      real = sched.phantom_for(date).tap(&:materialize!)
      phantom_id = "p-#{sched.id}-#{date.iso8601}"
      item = described_class.locate(phantom_id, agenda: agenda)
      expect(item).to eq(real)
      expect(item).not_to be_phantom
    end
  end

  describe "#complete! / #uncomplete!" do
    it "toggles completed_at" do
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: Time.current)
      expect { item.complete! }.to change { item.completed_at }.from(nil)
      expect { item.uncomplete! }.to change { item.completed_at }.to(nil)
    end
  end

  describe "Jil trigger lifecycle" do
    # Capture (scope, action) at call time — with_jil_attrs mutates a single
    # AgendaItem instance, so checking arg state after-the-fact would always
    # see the latest action. The block stub snapshots the symbol per call.
    def trigger_capture
      triggered = []
      allow(::Jil).to receive(:trigger) { |_user, scope, data, **|
        triggered << [scope, data[:action]]
      }
      triggered
    end

    it "fires :agenda_item action=:created on create" do
      triggered = trigger_capture
      create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      expect(triggered).to include([:agenda_item, :created])
    end

    it "fires :agenda_item action=:updated on update" do
      triggered = trigger_capture
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      item.update!(name: "Renamed")
      expect(triggered).to eq([[:agenda_item, :created], [:agenda_item, :updated]])
    end

    it "fires :agenda_item action=:destroyed on destroy" do
      triggered = trigger_capture
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      item.destroy!
      expect(triggered).to eq([[:agenda_item, :created], [:agenda_item, :destroyed]])
    end

    it "does NOT refire on a metadata-only update (avoids Jil-write retrigger loop)" do
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      triggered = trigger_capture
      item.update!(metadata: { travel_minutes: 12 })
      expect(triggered).to be_empty
    end

    it "DOES refire when metadata changes alongside another field" do
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      triggered = trigger_capture
      item.update!(metadata: { travel_minutes: 12 }, name: "Renamed")
      expect(triggered).to eq([[:agenda_item, :updated]])
    end

    it "DOES refire when arrive_early_minutes changes (real column, not metadata)" do
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      triggered = trigger_capture
      item.update!(arrive_early_minutes: 10)
      expect(triggered).to eq([[:agenda_item, :updated]])
    end
  end

  describe "arrive_early_minutes column" do
    it "defaults to 0" do
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      expect(item.reload.arrive_early_minutes).to eq(0)
    end

    it "round-trips an integer" do
      item = create(:agenda_item, agenda: agenda, kind: "task",
        start_at: 1.hour.from_now, arrive_early_minutes: 15)
      expect(item.reload.arrive_early_minutes).to eq(15)
    end

    it "is included in serialize" do
      item = create(:agenda_item, agenda: agenda, kind: "task",
        start_at: 1.hour.from_now, arrive_early_minutes: 10)
      expect(item.serialize).to include("arrive_early_minutes" => 10)
    end
  end

  describe "metadata column" do
    it "round-trips a hash via jsonb" do
      item = create(:agenda_item, agenda: agenda, kind: "task",
        start_at: 1.hour.from_now, metadata: { travel_minutes: 25, travel_location: "123 Main" })
      expect(item.reload.metadata).to eq("travel_minutes" => 25, "travel_location" => "123 Main")
    end

    it "defaults to {}" do
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      expect(item.metadata).to eq({})
    end

    it "is included in #serialize" do
      item = create(:agenda_item, agenda: agenda, kind: "task",
        start_at: 1.hour.from_now, metadata: { travel_minutes: 7 })
      expect(item.serialize["metadata"]).to eq("travel_minutes" => 7)
    end
  end

  describe "attendee helpers" do
    let(:base) {
      {
        "attendees"     => [
          { "email" => "me@example.com", "self" => true, "response_status" => "needsAction" },
          { "email" => "boss@example.com", "response_status" => "accepted" },
        ],
        "organizer"     => { "email" => "boss@example.com" },
        "self_response" => "needsAction",
      }
    }

    it "exposes attendees / organizer / self_response off metadata" do
      item = create(:agenda_item, agenda: agenda, kind: "event",
        start_at: 1.hour.from_now, end_at: 2.hours.from_now, metadata: base)
      expect(item.attendees.size).to eq(2)
      expect(item.organizer["email"]).to eq("boss@example.com")
      expect(item.self_response).to eq("needsAction")
      expect(item.invite?).to be true
      expect(item.needs_response?).to be true
      expect(item.declined?).to be false
    end

    it "returns sensible defaults when metadata has no attendee block" do
      item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
      expect(item.attendees).to eq([])
      expect(item.organizer).to be_nil
      expect(item.self_response).to be_nil
      expect(item.invite?).to be false
      expect(item.needs_response?).to be false
      expect(item.declined?).to be false
    end

    it "serializes attendee fields for the FE" do
      item = create(:agenda_item, agenda: agenda, kind: "event",
        start_at: 1.hour.from_now, end_at: 2.hours.from_now,
        metadata: base.merge("self_response" => "declined"))
      payload = item.serialize
      expect(payload[:self_response]).to eq("declined")
      expect(payload[:declined]).to be true
      expect(payload[:needs_response]).to be false
      expect(payload[:attendees].size).to eq(2)
    end
  end

  describe "#presentation_attrs" do
    # Single source of truth for the data-* attribute payload shared by
    # `_data_attrs.html.erb` (server-rendered views) and
    # `seed_hydrator.js` (client-rendered cal views). Adding or removing
    # an entry here lands in both render paths automatically.
    before do
      # Block the inline-Sidekiq travel-chain-sync from making real Google
      # calls during the create — these specs aren't about chain behavior.
      address_book = instance_double("AddressBook")
      allow_any_instance_of(::User).to receive(:address_book).and_return(address_book)
      allow(address_book).to receive(:home).and_return(nil)
      allow(address_book).to receive(:match_contact).and_return(nil)
      allow(address_book).to receive(:geocode).and_return(nil)
      allow(address_book).to receive(:nearest_from_name).and_return(nil)
      allow(address_book).to receive(:traveltime_seconds).and_return(nil)
      allow(::AddressBook).to receive(:non_travelable?).and_return(false)
    end

    it "returns the kebab-case attribute hash both render paths iterate" do
      item = create(:agenda_item, agenda: agenda, kind: "event", name: "Dinner",
        location: "Texas Roadhouse", arrive_early_minutes: 10,
        start_at: Time.zone.local(2026, 6, 18, 20, 0),
        end_at:   Time.zone.local(2026, 6, 18, 22, 0),
        metadata: {
          "travel" => {
            "location_address"     => "11593 4000 W, South Jordan, UT 84009, USA",
            "travel_from"          => "Home St",
            "travel_from_kind"     => "home",
            "travel_minutes"       => 25,
            "chain_predecessor_id" => 99,
            "chain_successor_id"   => 100,
            "chain_prev_end_at"    => 1234,
            "leave_at"             => 5678,
          },
        })

      attrs = item.presentation_attrs
      expect(attrs).to include(
        "item-id"               => item.display_id,
        "item-url"              => "/agenda_items/#{item.display_id}",
        "kind"                  => "event",
        "name"                  => "Dinner",
        "location"              => "Texas Roadhouse",
        "resolved-address"      => "11593 4000 W, South Jordan, UT 84009, USA",
        "travel-from"           => "Home St",
        "travel-from-kind"      => "home",
        "chain-predecessor-id"  => 99,
        "chain-successor-id"    => 100,
        "chain-prev-end-epoch"  => 1234,
        "leave-at-epoch"        => 5678,
        "arrive-early-minutes"  => 10,
        "travel-minutes"        => 25,
      )
    end

    it "is included in #serialize output under :presentation_attrs so seed_hydrator can iterate it" do
      item = create(:agenda_item, agenda: agenda, kind: :task, name: "Foo",
        start_at: 1.hour.from_now)
      expect(item.serialize[:presentation_attrs]).to eq(item.presentation_attrs)
    end

    it "tolerates a blank/missing travel metadata hash without raising" do
      item = create(:agenda_item, agenda: agenda, kind: :task, name: "Foo",
        start_at: 1.hour.from_now, metadata: {})
      attrs = item.presentation_attrs
      expect(attrs["resolved-address"]).to be_nil
      expect(attrs["travel-minutes"]).to eq(0)
      expect(attrs["chain-predecessor-id"]).to be_nil
    end

    # The legacy top-level `metadata["travel_minutes"]` mirror was retired —
    # any leftover value (e.g. stale data from a pre-cleanup write) must be
    # ignored. The nested travel hash is the only source of truth.
    it "ignores any stale top-level travel_minutes — nested is the only source" do
      item = create(:agenda_item, agenda: agenda, kind: "event", name: "Return Home",
        location: "Greens Lake Campground",
        start_at: Time.zone.local(2026, 6, 25, 17, 0),
        end_at:   Time.zone.local(2026, 6, 25, 18, 0),
        metadata: {
          "travel_minutes" => 216, # stale, must NOT be read
          "travel"         => {
            "travel_minutes" => 0,
            "travel_from"    => "Greens Lake Campground",
          },
        })

      expect(item.presentation_attrs["travel-minutes"]).to eq(0)
    end

    # Regression guard for "all-day events span two days in the cal_week
    # banner row". `end-date` must be the INCLUSIVE last-day midnight in
    # the user's tz — NOT `end_at` (which is the exclusive next-day midnight
    # per Google convention) and NOT `Date#to_time` (which lands in
    # Rails Time.zone, defaulting to UTC and silently shifting the day
    # for any user whose tz differs).
    # `user.timezone` is hardcoded "America/Denver" on the User model
    # (not a per-user column), so these specs simply assert the math
    # against that fixed value.
    it "emits end-date as inclusive last-day midnight in the user's tz for single-day all-day" do
      zone = ::ActiveSupport::TimeZone["America/Denver"]
      item = create(:agenda_item, agenda: agenda, kind: :event, name: "Bday",
        all_day: true,
        start_at: zone.local(2026, 6, 21),
        end_at:   zone.local(2026, 6, 22)) # exclusive

      attrs = item.presentation_attrs
      # For a single-day all-day event, end-date must equal start-at so
      # the cal-week chip spans exactly one column.
      expect(attrs["end-date"]).to eq(attrs["start-at"])
      # And NOT the exclusive end_at — that's the bug we're guarding.
      expect(attrs["end-date"]).not_to eq(attrs["end-at"])
    end

    it "emits end-date == start-at + 2 days for a three-day all-day event" do
      zone = ::ActiveSupport::TimeZone["America/Denver"]
      item = create(:agenda_item, agenda: agenda, kind: :event, name: "Trip",
        all_day: true,
        start_at: zone.local(2026, 6, 21),
        end_at:   zone.local(2026, 6, 24)) # exclusive

      attrs = item.presentation_attrs
      # Last inclusive day is 2026-06-23; start_at is 2026-06-21 midnight.
      expect(attrs["end-date"]).to eq(attrs["start-at"] + (2 * 86_400))
    end
  end
end
