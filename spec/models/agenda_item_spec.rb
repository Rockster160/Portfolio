# == Schema Information
#
# Table name: agenda_items
#
#  id                   :bigint           not null, primary key
#  agenda_id            :bigint           not null
#  agenda_schedule_id   :bigint
#  kind                 :integer          not null
#  start_at             :datetime         not null
#  end_at               :datetime
#  completed_at         :datetime
#  detached_at          :datetime
#  name                 :string           not null
#  notes                :text
#  location             :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  color                :string
#  trigger_expression   :text
#  notified_at          :datetime
#  original_start_at    :datetime
#  external_uid         :text
#  external_etag        :text
#  external_updated_at  :datetime
#  all_day              :boolean          default(FALSE), not null
#  locally_modified_at  :datetime
#  local_color          :string
#  cancelled_at         :datetime
#  status               :integer          default("confirmed"), not null
#  fired_at             :datetime
#  ended_fired_at       :datetime
#  metadata             :jsonb            not null
#  arrive_early_minutes :integer          default(0), not null
#  client_mutation_id   :string
#  travel_nav_address   :string
#

require "rails_helper"

RSpec.describe AgendaItem do
  describe "the model" do
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

    # The outgoing leg. It has been computed since 30 Jul and, until now, read
    # on the Ruby side by exactly one method — `presentation_attrs`, for the
    # screen. Prod 5266 asked "when does she get back from yoga" and got a
    # question back, because nothing else could reach it.
    describe "the drive home" do
      def item_with(travel, ends: Time.zone.local(2026, 9, 8, 13, 0))
        build(
          :agenda_item, agenda: agenda, kind: "event",
          start_at: ends - 90.minutes, end_at: ends, metadata: { "travel" => travel }
        )
      end

      it "reads the stamped arrival when there is one" do
        stamped = Time.zone.local(2026, 9, 8, 13, 31).to_i
        item = item_with({ "post_travel_seconds" => 1860, "post_arrive_at" => stamped })

        expect(item.home_at.to_i).to eq(stamped)
      end

      # A phantom carries the SCHEDULE's metadata, which mirrors the baseline
      # and not the per-date epoch — so every occurrence past the 30-hour
      # materialize window has a drive home and no arrival stamped on it. That
      # is most of them, and it is the case prod 5266 actually hit.
      it "works the arrival out from its own end when nothing is stamped" do
        item = item_with({ "post_travel_seconds" => 1860 })

        expect(item.home_at).to eq(Time.zone.local(2026, 9, 8, 13, 31))
      end

      it "has no arrival when there is no drive home" do
        expect(item_with({ "travel_seconds" => 900 }).home_at).to be_nil
      end

      it "has no arrival when it has no end to measure from" do
        item = build(
          :agenda_item, agenda: agenda, kind: "task", end_at: nil,
          metadata: { "travel" => { "post_travel_seconds" => 1860 } }
        )

        expect(item.home_at).to be_nil
      end

      it "rounds the minutes up rather than reporting a drive as shorter" do
        expect(item_with({ "post_travel_seconds" => 1812 }).travel_home_minutes).to eq(31)
      end

      it "prefers the stored minutes when they are there" do
        item = item_with({ "post_travel_seconds" => 1812, "post_travel_minutes" => 31 })

        expect(item.travel_home_minutes).to eq(31)
      end
    end

    # The legacy pair — `travel_minutes` + `travel_location`, which is what the
    # Jil refresh task writes — carries no seconds. Reading the key directly
    # made a 47-minute drive read as no drive at all (prod 5268).
    describe "#travel_seconds" do
      it "falls back to the minute figure" do
        item = build(
          :agenda_item, agenda: agenda,
          metadata: { "travel" => { "travel_minutes" => 47, "travel_location" => "Horsetail Falls" } }
        )

        expect(item.travel_seconds).to eq(2820)
      end

      it "prefers the seconds when both are there" do
        item = build(
          :agenda_item, agenda: agenda,
          metadata: { "travel" => { "travel_minutes" => 47, "travel_seconds" => 2793 } }
        )

        expect(item.travel_seconds).to eq(2793)
      end

      it "is nil when there is no travel at all" do
        expect(build(:agenda_item, agenda: agenda, metadata: {}).travel_seconds).to be_nil
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

  describe "query — is:<state> markers" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }

    let(:overdue_task) {
      create(:agenda_item, agenda: agenda, kind: "task",
        start_at: 2.days.ago, completed_at: nil, name: "Overdue Task")
    }
    let(:completed_task) {
      create(:agenda_item, agenda: agenda, kind: "task",
        start_at: 2.days.ago, completed_at: 1.day.ago, name: "Done Task")
    }
    let(:upcoming_event) {
      create(:agenda_item, agenda: agenda, kind: "event",
        start_at: 2.days.from_now, end_at: 2.days.from_now + 1.hour, name: "Future Event")
    }
    let(:current_event) {
      create(:agenda_item, agenda: agenda, kind: "event",
        start_at: 1.hour.ago, end_at: 1.hour.from_now, name: "Ongoing Event")
    }

    before { overdue_task; completed_task; upcoming_event; current_event }

    it "kind:task narrows by enum-as-string" do
      expect(AgendaItem.query("kind:task")).to contain_exactly(overdue_task, completed_task)
    end

    it "is:task is equivalent to kind:task" do
      expect(AgendaItem.query("is:task")).to contain_exactly(overdue_task, completed_task)
    end

    it "is:event narrows by event kind" do
      expect(AgendaItem.query("is:event")).to contain_exactly(upcoming_event, current_event)
    end

    it "combines is: filters: kind:task is:incomplete is:overdue narrows to overdue incomplete tasks" do
      expect(AgendaItem.query("kind:task is:incomplete is:overdue")).to contain_exactly(overdue_task)
    end

    it "is:overdue excludes events (events auto-disappear when end_at passes)" do
      _past_event = create(:agenda_item, agenda: agenda, kind: "event",
        start_at: 3.days.ago, end_at: 3.days.ago + 1.hour,
        completed_at: nil, name: "Past Meeting")

      expect(AgendaItem.query("is:overdue")).to contain_exactly(overdue_task)
      expect(AgendaItem.query("is:overdue").pluck(:kind)).not_to include("event")
    end

    it "is:upcoming keeps events visible until end_at; non-events disappear at start_at" do
      expect(AgendaItem.query("is:upcoming")).to contain_exactly(upcoming_event, current_event)
    end

    it "is:past flips events at end_at and non-events at start_at" do
      past_event = create(:agenda_item, agenda: agenda, kind: "event",
        start_at: 3.hours.ago, end_at: 1.hour.ago, name: "Done Meeting")

      results = AgendaItem.query("is:past")
      expect(results).to include(past_event, overdue_task, completed_task)
      expect(results).not_to include(current_event, upcoming_event)
    end

    it "name:Overdue does a name ILIKE search" do
      expect(AgendaItem.query("name:Overdue")).to contain_exactly(overdue_task)
    end

    it "is:recurring narrows to items linked to a schedule" do
      sched = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "daily" }, starts_on: Date.current)
      # Saving the schedule already materialized its upcoming occurrences; clear
      # them so this is about the filter rather than about how many rows the
      # materialization window happened to produce at this hour.
      AgendaItem.where(agenda_schedule_id: sched.id).delete_all
      recurring_item = sched.agenda_items.create!(agenda: agenda, kind: "task",
        name: "From schedule", start_at: 1.day.ago)
      expect(AgendaItem.query("is:recurring")).to contain_exactly(recurring_item)
    end

    it "bare 'upcoming' is treated as free-text, NOT a state filter" do
      upcoming_named = create(:agenda_item, agenda: agenda, kind: "task",
        name: "Upcoming review", start_at: 5.days.from_now, completed_at: nil)
      results = AgendaItem.query("upcoming")
      expect(results).to include(upcoming_named)
      expect(results).not_to include(overdue_task)
      expect(results).not_to include(upcoming_event)
    end

    it "bare 'event' is treated as free-text, NOT a kind filter" do
      name_match = create(:agenda_item, agenda: agenda, kind: "task",
        name: "Plan the event", start_at: 1.day.from_now, completed_at: nil)
      # Free-text matches the literal word; kind:event filter would have
      # excluded this task. We expect the task TO appear and the existing
      # bare kind: "event" rows (Future Event, Ongoing Event) to also appear
      # because both contain "event" in the name.
      results = AgendaItem.query("event")
      expect(results).to include(name_match)
      # Items whose name does NOT contain "event" are excluded.
      expect(results).not_to include(completed_task) # "Done Task" — no "event"
    end
  end
end
