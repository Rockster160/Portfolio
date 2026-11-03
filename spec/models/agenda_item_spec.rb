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

    it "requires an event to end after it starts" do
      now = Time.current
      expect(build(:agenda_item, agenda: agenda, kind: "event", end_at: nil)).not_to be_valid
      expect(build(:agenda_item, agenda: agenda, kind: "event", start_at: now, end_at: now)).not_to be_valid
    end

    # A phantom carries the SCHEDULE's metadata, which mirrors the baseline and
    # not the per-date epoch, so most occurrences have a drive home with no
    # arrival stamped on it. The legacy pair (`travel_minutes` +
    # `travel_location`, what the Jil refresh task writes) carries no seconds.
    describe "the drive home and the drive there" do
      def item_with(travel, ends: Time.zone.local(2026, 9, 8, 13, 0))
        build(
          :agenda_item, agenda: agenda, kind: "event",
          start_at: ends - 90.minutes, end_at: ends, metadata: { "travel" => travel }
        )
      end

      it "reads a stamped arrival home, or works it out from the end", :aggregate_failures do
        stamped = Time.zone.local(2026, 9, 8, 13, 31).to_i
        expect(item_with({ "post_travel_seconds" => 1860, "post_arrive_at" => stamped }).home_at.to_i).to eq(stamped)
        expect(item_with({ "post_travel_seconds" => 1860 }).home_at).to eq(Time.zone.local(2026, 9, 8, 13, 31))
        expect(item_with({ "travel_seconds" => 900 }).home_at).to be_nil
        task = build(
          :agenda_item, agenda: agenda, kind: "task", end_at: nil,
          metadata: { "travel" => { "post_travel_seconds" => 1860 } }
        )
        expect(task.home_at).to be_nil
      end

      it "rounds the minutes home up, preferring the stored figure" do
        expect(item_with({ "post_travel_seconds" => 1812 }).travel_home_minutes).to eq(31)
        expect(item_with({ "post_travel_seconds" => 1812, "post_travel_minutes" => 31 }).travel_home_minutes).to eq(31)
      end

      it "reads the drive there in seconds, falling back to the minute figure", :aggregate_failures do
        expect(item_with({ "travel_minutes" => 47, "travel_location" => "Horsetail Falls" }).travel_seconds).to eq(2820)
        expect(item_with({ "travel_minutes" => 47, "travel_seconds" => 2793 }).travel_seconds).to eq(2793)
        expect(build(:agenda_item, agenda: agenda, metadata: {}).travel_seconds).to be_nil
      end
    end

    describe "moving to another agenda" do
      let(:other) { create(:agenda, user: agenda.user, color: "#00D431") }

      it "drops the old agenda's color so the new one shows" do
        item = create(:agenda_item, agenda: agenda, color: agenda.color.downcase)
        item.update!(agenda: other)
        expect(item.reload.color).to be_nil
        expect(item.display_color).to eq("#00D431")
      end

      it "keeps a color picked to differ from the old agenda" do
        item = create(:agenda_item, agenda: agenda, color: "#FF0000")
        item.update!(agenda: other)
        expect(item.reload.color).to eq("#FF0000")
      end
    end

    describe "#crossed_out?" do
      let(:now) { Time.zone.local(2026, 5, 13, 12, 0) }

      it "crosses out a completed task and an event whose end has passed" do
        task = create(:agenda_item, agenda: agenda, kind: "task",
          start_at: now - 2.hours, completed_at: now - 1.hour)
        event = create(:agenda_item, agenda: agenda, kind: "event",
          start_at: now - 2.hours, end_at: now - 1.hour)
        expect(task.crossed_out?(now: now)).to be true
        expect(event.crossed_out?(now: now)).to be true
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

      it "AgendaItem.locate resolves a phantom_id, or the real row once materialized" do
        date = Date.current + 7.days
        phantom_id = "p-#{sched.id}-#{date.iso8601}"

        item = described_class.locate(phantom_id, agenda: agenda)
        expect(item).to be_phantom
        expect(item.agenda_schedule_id).to eq(sched.id)

        real = sched.phantom_for(date).tap(&:materialize!)
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

      it "fires :created, :updated and :destroyed through the lifecycle" do
        triggered = trigger_capture
        item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
        item.update!(name: "Renamed")
        item.destroy!
        expect(triggered).to eq([[:agenda_item, :created], [:agenda_item, :updated], [:agenda_item, :destroyed]])
      end

      # A Jil task writing travel metadata back must not retrigger itself.
      it "refires on a real column change, not on a metadata-only one" do
        item = create(:agenda_item, agenda: agenda, kind: "task", start_at: 1.hour.from_now)
        triggered = trigger_capture

        item.update!(metadata: { travel_minutes: 12 })
        expect(triggered).to be_empty

        item.update!(metadata: { travel_minutes: 13 }, name: "Renamed")
        item.update!(arrive_early_minutes: 10)
        expect(triggered).to eq([[:agenda_item, :updated], [:agenda_item, :updated]])
      end
    end

    it "carries arrive_early_minutes and metadata in serialize" do
      item = create(:agenda_item, agenda: agenda, kind: "task",
        start_at: 1.hour.from_now, arrive_early_minutes: 10, metadata: { travel_minutes: 7 })
      expect(item.serialize).to include("arrive_early_minutes" => 10)
      expect(item.serialize["metadata"]).to eq("travel_minutes" => 7)
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

      # `end-date` must be the INCLUSIVE last-day midnight in the user's zone,
      # not `end_at` (the exclusive next-day midnight per Google convention)
      # and not `Date#to_time` (which lands in the Rails zone and shifts the day).
      it "emits end-date as the inclusive last day of an all-day event" do
        zone = ::ActiveSupport::TimeZone["America/Denver"]
        bday = create(:agenda_item, agenda: agenda, kind: :event, name: "Bday",
          all_day: true, start_at: zone.local(2026, 6, 21), end_at: zone.local(2026, 6, 22))
        trip = create(:agenda_item, agenda: agenda, kind: :event, name: "Trip",
          all_day: true, start_at: zone.local(2026, 6, 21), end_at: zone.local(2026, 6, 24))

        one_day = bday.presentation_attrs
        expect(one_day["end-date"]).to eq(one_day["start-at"])
        expect(one_day["end-date"]).not_to eq(one_day["end-at"])
        three_day = trip.presentation_attrs
        expect(three_day["end-date"]).to eq(three_day["start-at"] + (2 * 86_400))
      end
    end

    # Every open Agenda repaints off one MonitorChannel broadcast. A row added
    # or moved by Byte, an undo or a script has to announce itself too, so the
    # announcement belongs to the record, not to whoever wrote it.
    describe "the live-update broadcast" do
      def agenda_payloads
        payloads = []
        allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload| payloads << payload }
        yield
        payloads.select { |p| p[:id] == :agenda }
      end

      it "announces a row created outside a controller, a move, and a destroyed id" do
        sent = agenda_payloads { create(:agenda_item, agenda: agenda, name: "Byte added this") }
        expect(sent.size).to eq(1)
        expect(sent.first[:data][:changed].map { |c| c[:agenda_id] }).to eq([agenda.id])

        item = create(:agenda_item, agenda: agenda)
        expect(agenda_payloads { item.update!(start_at: 3.hours.from_now) }.size).to eq(1)

        id = item.id.to_s
        expect(agenda_payloads { item.destroy! }.first[:data][:destroyed_item_ids]).to eq([id])
      end

      it "tells someone who can't see where it went to drop it" do
        viewer = create(:user)
        AgendaShare.create!(agenda: agenda, user: viewer)
        hidden = create(:agenda, user: agenda.user)
        item = create(:agenda_item, agenda: agenda)
        sent = []
        allow(MonitorChannel).to receive(:broadcast_to) { |u, payload| sent << [u.id, payload] }

        item.update!(agenda: hidden)

        drops = sent.select { |_, p| p[:data][:destroyed_item_ids].present? }
        expect(drops.map(&:first)).to eq([viewer.id])
        expect(drops.sole.last[:data][:destroyed_item_ids]).to eq([item.id.to_s])
      end

      # Rails runs after_commit on a save that changed nothing, and the schedule
      # worker re-saves every materialized occurrence each tick. A Jil-side
      # travel-time cache write is not news to the calendar either.
      it "stays quiet on a save that changed nothing, or only metadata" do
        item = create(:agenda_item, agenda: agenda)

        expect(agenda_payloads { item.update!(name: item.name) }).to be_empty
        expect(agenda_payloads { item.update!(metadata: { "travel" => { "seconds" => 600 } }) }).to be_empty
      end

      # The importer walks hundreds of rows and fans out once at the end.
      it "leaves the Google importer's own single fan-out to it" do
        key = ::GoogleCalendar::Sync::SUPPRESS_KEY
        Thread.current[key] = true
        sent = agenda_payloads { create(:agenda_item, agenda: agenda) }
        Thread.current[key] = nil

        expect(sent).to be_empty
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

    # Events stay upcoming until end_at and never go overdue; other kinds flip
    # at start_at.
    it "narrows by kind and is:<state>", :aggregate_failures do
      create(:agenda_item, agenda: agenda, kind: "event",
        start_at: 3.days.ago, end_at: 3.days.ago + 1.hour, completed_at: nil, name: "Past Meeting")
      {
        "kind:task"                          => [overdue_task, completed_task],
        "is:task"                            => [overdue_task, completed_task],
        "kind:task is:incomplete is:overdue" => [overdue_task],
        "is:overdue"                         => [overdue_task],
        "is:upcoming"                        => [upcoming_event, current_event],
        "name:Overdue"                       => [overdue_task],
      }.each do |query, want|
        expect(AgendaItem.query(query).to_a).to match_array(want), query
      end
      expect(AgendaItem.query("is:event")).to include(upcoming_event, current_event)
      expect(AgendaItem.query("is:event")).not_to include(overdue_task, completed_task)
    end

    it "is:past flips events at end_at and non-events at start_at" do
      past_event = create(:agenda_item, agenda: agenda, kind: "event",
        start_at: 3.hours.ago, end_at: 1.hour.ago, name: "Done Meeting")

      results = AgendaItem.query("is:past")
      expect(results).to include(past_event, overdue_task, completed_task)
      expect(results).not_to include(current_event, upcoming_event)
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

    it "treats a bare state or kind word as free text, not a filter" do
      upcoming_named = create(:agenda_item, agenda: agenda, kind: "task",
        name: "Upcoming review", start_at: 5.days.from_now, completed_at: nil)
      event_named = create(:agenda_item, agenda: agenda, kind: "task",
        name: "Plan the event", start_at: 1.day.from_now, completed_at: nil)

      upcoming = AgendaItem.query("upcoming")
      expect(upcoming).to include(upcoming_named)
      expect(upcoming).not_to include(overdue_task, upcoming_event)

      event = AgendaItem.query("event")
      expect(event).to include(event_named)
      expect(event).not_to include(completed_task)
    end
  end
end
