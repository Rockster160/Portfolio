require "rails_helper"

# Core chain detection + persistence. All AddressBook hits are stubbed
# deterministically so we can pin overlap math without Google network round
# trips. Cases focus on shape: chain forms vs not, before/after, drop-outs,
# fingerprint short-circuit, midnight rollover.
RSpec.describe AgendaTravelChain::Service do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }

  let(:home_address) { instance_double("Address", street: "Home St", loc: [40.5, -111.9]) }

  # Drive-time matrix in seconds. Keys are [from_text, to_text]; symmetric.
  # All other from/to pairs default to 600s.
  let(:drive_matrix) {
    {
      ["Home St", "Office"]   => 600,    # 10 min
      ["Office",  "Home St"]  => 600,
      ["Home St", "Gym"]      => 1200,   # 20 min
      ["Gym",     "Home St"]  => 1200,
      ["Office",  "Gym"]      => 600,    # 10 min
      ["Gym",     "Office"]   => 600,
      ["Home St", "Far"]      => 7200,   # 2 hours
      ["Far",     "Home St"]  => 7200,
    }
  }

  let(:address_book) { instance_double("AddressBook") }

  before do
    # Stub at any-instance level so the worker — which re-loads User by id —
    # also picks up the stub. Inline Sidekiq + after_commit callback would
    # otherwise route through the real AddressBook + Google.
    allow_any_instance_of(::User).to receive(:address_book).and_return(address_book)
    allow(address_book).to receive(:home).and_return(home_address)
    # Default to no contact match — individual specs can override when testing
    # the contact-first branch added in resolver.rb.
    allow(address_book).to receive(:match_contact).and_return(nil)
    allow(address_book).to receive(:geocode) { |addr| [40.0 + addr.to_s.length * 0.001, -111.0] }
    allow(address_book).to receive(:traveltime_seconds) { |to, from, _opts = {}|
      drive_matrix[[from.to_s, to.to_s]] || 600
    }
    allow(::AddressBook).to receive(:non_travelable?).and_return(false)
  end

  def make_event(name:, start_at:, end_at:, location:, **rest)
    agenda.agenda_items.create!(
      name:      name,
      kind:      :event,
      start_at:  start_at,
      end_at:    end_at,
      location:  location,
      **rest,
    )
  end

  describe "#run" do
    it "does nothing when there are no candidate events" do
      AgendaTravelChain::Service.new(user, Date.new(2026, 6, 18)).run
      # No raise; no events touched.
      expect(agenda.agenda_items.count).to eq(0)
    end

    it "writes solo metadata for a single isolated event" do
      evt = make_event(
        name: "Solo meeting",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "Office",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      meta = evt.reload.metadata["travel"]
      expect(meta).to be_present
      expect(meta["chain_predecessor_id"]).to be_nil
      expect(meta["chain_successor_id"]).to be_nil
      expect(meta["chain_head_id"]).to eq(evt.id)
      expect(meta["travel_from"]).to eq("Home St")
      expect(meta["travel_from_kind"]).to eq("home")
      expect(meta["travel_seconds"]).to eq(600)
      expect(meta["travel_minutes"]).to eq(10)
    end

    it "uses metadata.travel.location_address for Distance Matrix when the raw text was resolved via Places (e.g. 'Texas Roadhouse')" do
      resolved = "11593 4000 W, South Jordan, UT 84009, USA"
      # Stubs must be in place BEFORE make_event because the inline-Sidekiq
      # auto-sync fires off the create's after_commit and writes the
      # fingerprint; a later override would be short-circuited by it.
      allow(address_book).to receive(:geocode) { |addr|
        next nil if addr == "Texas Roadhouse"
        [40.0 + addr.to_s.length * 0.001, -111.0]
      }
      allow(address_book).to receive(:nearest_from_name) { |_name, **opts|
        case opts[:extract]
        when :address then resolved
        when :loc then [40.54, -111.98]
        end
      }
      # Distance Matrix only succeeds for the resolved address — proves the
      # service is passing the resolved value, not the raw "Texas Roadhouse".
      allow(address_book).to receive(:traveltime_seconds) { |to, from, _opts = {}|
        if from == "Home St" && to == resolved
          1500
        elsif from == "Home St" && to == "Texas Roadhouse"
          nil # what would happen pre-fix
        else
          drive_matrix[[from.to_s, to.to_s]] || 600
        end
      }

      evt = make_event(
        name: "Dinner",
        start_at: Time.zone.parse("2026-06-18 20:00"),
        end_at:   Time.zone.parse("2026-06-18 22:00"),
        location: "Texas Roadhouse",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      meta = evt.reload.metadata["travel"]
      expect(meta["location_address"]).to eq(resolved)
      expect(meta["travel_seconds"]).to eq(1500)
      expect(meta["travel_minutes"]).to eq(25)
    end

    it "chains two events when going home in between wouldn't fit" do
      a = make_event(
        name: "Meeting A",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "Office",
      )
      b = make_event(
        name: "Workout",
        start_at: Time.zone.parse("2026-06-18 15:15"),
        end_at:   Time.zone.parse("2026-06-18 16:15"),
        location: "Gym",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      a_meta = a.reload.metadata["travel"]
      b_meta = b.reload.metadata["travel"]
      expect(a_meta["chain_successor_id"]).to eq(b.id)
      expect(b_meta["chain_predecessor_id"]).to eq(a.id)
      expect(b_meta["chain_head_id"]).to eq(a.id)
      expect(a_meta["chain_head_id"]).to eq(a.id)
      expect(b_meta["travel_from"]).to eq("Office")
      expect(b_meta["travel_from_kind"]).to eq("event")
      expect(b_meta["travel_seconds"]).to eq(600)  # Office→Gym
      expect(b_meta["chain_prev_end_at"]).to eq(a.end_at.to_i)
    end

    it "does NOT chain when the gap is large enough to go home" do
      a = make_event(
        name: "Morning meeting",
        start_at: Time.zone.parse("2026-06-18 09:00"),
        end_at:   Time.zone.parse("2026-06-18 10:00"),
        location: "Office",
      )
      b = make_event(
        name: "Evening workout",
        start_at: Time.zone.parse("2026-06-18 18:00"),
        end_at:   Time.zone.parse("2026-06-18 19:00"),
        location: "Gym",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      a_meta = a.reload.metadata["travel"]
      b_meta = b.reload.metadata["travel"]
      expect(a_meta["chain_successor_id"]).to be_nil
      expect(b_meta["chain_predecessor_id"]).to be_nil
      expect(b_meta["travel_from_kind"]).to eq("home")
    end

    it "excludes nonav events from the chain entirely" do
      a = make_event(
        name: "Office",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "Office",
      )
      _virtual = make_event(
        name: "Virtual meeting",
        start_at: Time.zone.parse("2026-06-18 15:05"),
        end_at:   Time.zone.parse("2026-06-18 15:15"),
        location: "Some place",
        notes:    "nonav",
      )
      c = make_event(
        name: "Gym",
        start_at: Time.zone.parse("2026-06-18 15:20"),
        end_at:   Time.zone.parse("2026-06-18 16:20"),
        location: "Gym",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      # nonav event should have no travel metadata
      virtual = agenda.agenda_items.find_by(name: "Virtual meeting")
      expect(virtual.metadata["travel"]).to be_nil

      # A and C evaluate as if the virtual event isn't there.
      a_meta = a.reload.metadata["travel"]
      c_meta = c.reload.metadata["travel"]
      expect(a_meta["chain_successor_id"]).to eq(c.id)
      expect(c_meta["chain_predecessor_id"]).to eq(a.id)
    end

    it "skips all_day events from chain candidacy" do
      make_event(
        name: "Holiday",
        start_at: Time.zone.parse("2026-06-18 00:00"),
        end_at:   Time.zone.parse("2026-06-19 00:00"),
        location: "Office",
        all_day:  true,
      )
      described_class.new(user, Date.new(2026, 6, 18)).run
      holiday = agenda.agenda_items.first
      expect(holiday.metadata["travel"]).to be_nil
    end

    it "skips events whose location is non-travelable (Google Meet, Zoom, etc.)" do
      allow(::AddressBook).to receive(:non_travelable?).and_call_original

      virtual = make_event(
        name: "Standup",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "https://meet.google.com/abc-defg-hij",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run
      expect(virtual.reload.metadata["travel"]).to be_nil
    end

    it "skips events on agendas listed in EXCLUDED_AGENDA_FRAGMENTS" do
      ocs_agenda = create(:agenda, user: user, name: "rocco@oneclaimsolution.com")
      ocs_evt = ocs_agenda.agenda_items.create!(
        kind:     :event,
        name:     "Work meeting",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "Office",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run
      expect(ocs_evt.reload.metadata["travel"]).to be_nil
    end

    it "skips events with blank locations" do
      no_loc = make_event(
        name: "Phone call",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run
      expect(no_loc.reload.metadata["travel"]).to be_nil
    end

    it "clears stale chain metadata when an event drops out (location cleared)" do
      a = make_event(
        name: "A",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "Office",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run
      expect(a.reload.metadata["travel"]).to be_present

      # Clear the location via update_columns to skip the after_commit
      # (we're testing Service in isolation, not the callback flow).
      a.update_columns(location: nil)
      described_class.new(user, Date.new(2026, 6, 18)).run
      expect(a.reload.metadata["travel"]).to be_nil
    end

    it "preserves nested travel metadata on non-event items (kind=task)" do
      task_item = agenda.agenda_items.create!(
        kind:     :task,
        name:     "Pick up wine",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 14:30"),
        location: "Liquor Store",
        metadata: {
          "travel" => { "travel_minutes" => 10, "travel_location" => "Liquor Store" },
          "travel_minutes" => 10, "travel_location" => "Liquor Store",
        },
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      reloaded = task_item.reload
      expect(reloaded.metadata["travel"]).to include(
        "travel_minutes" => 10, "travel_location" => "Liquor Store",
      )
      expect(reloaded.metadata["travel_minutes"]).to eq(10)
      expect(reloaded.metadata["travel_location"]).to eq("Liquor Store")
    end

    it "is a no-op on a second run when inputs are unchanged (fingerprint short-circuit)" do
      make_event(
        name: "Solo",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "Office",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      # On the second run with identical inputs, AddressBook#geocode is not
      # called again — the location_fingerprint short-circuits.
      reset_count = 0
      allow(address_book).to receive(:geocode) { |_addr|
        reset_count += 1
        [40.5, -111.0]
      }
      described_class.new(user, Date.new(2026, 6, 18)).run
      expect(reset_count).to eq(0)
    end

    it "uses before: list's first entry as the incoming location for chain math" do
      a = make_event(
        name: "Stop on the way",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "Office",
        notes:    "before:Gym",  # so we drive Home→Gym→Office
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      meta = a.reload.metadata["travel"]
      expect(meta["overrides"]["before"]).to eq(["Gym"])
      # Drive seconds should be Home→Gym (1200), not Home→Office (600).
      expect(meta["travel_seconds"]).to eq(1200)
    end

    describe "backfill mode" do
      def seed_cached_travel(item, seconds)
        item.update_columns(metadata: item.metadata.merge("travel" => { "travel_seconds" => seconds }))
      end

      it "uses cached travel_seconds for the home-leg overlap check (no Google for symmetric assumption)" do
        a = make_event(name: "A", start_at: Time.zone.parse("2026-06-18 14:00"), end_at: Time.zone.parse("2026-06-18 15:00"), location: "Office")
        b = make_event(name: "B", start_at: Time.zone.parse("2026-06-18 15:15"), end_at: Time.zone.parse("2026-06-18 16:15"), location: "Gym")
        seed_cached_travel(a, 600)
        seed_cached_travel(b, 600)

        # In backfill mode the home-leg is read from cache. Only the
        # chain-confirmed A→B drive should hit AddressBook.
        expect(address_book).not_to receive(:traveltime_seconds).with("Home St", anything, anything)
        expect(address_book).not_to receive(:traveltime_seconds).with(anything, "Home St", anything)
        expect(address_book).to receive(:traveltime_seconds).with("Gym", "Office", anything).and_return(600).at_least(:once)

        described_class.new(user, Date.new(2026, 6, 18), mode: :backfill).run

        expect(a.reload.metadata.dig("travel", "chain_successor_id")).to eq(b.id)
        expect(b.reload.metadata.dig("travel", "chain_predecessor_id")).to eq(a.id)
      end

      it "does NOT chain when cached travel_seconds don't satisfy the overlap rule" do
        a = make_event(name: "A", start_at: Time.zone.parse("2026-06-18 09:00"), end_at: Time.zone.parse("2026-06-18 10:00"), location: "Office")
        b = make_event(name: "B", start_at: Time.zone.parse("2026-06-18 18:00"), end_at: Time.zone.parse("2026-06-18 19:00"), location: "Gym")
        seed_cached_travel(a, 600)
        seed_cached_travel(b, 600)

        # Gap is huge — no chain. Nothing should hit the Distance Matrix.
        expect(address_book).not_to receive(:traveltime_seconds)
        described_class.new(user, Date.new(2026, 6, 18), mode: :backfill).run

        expect(a.reload.metadata.dig("travel", "chain_successor_id")).to be_nil
        expect(b.reload.metadata.dig("travel", "chain_predecessor_id")).to be_nil
      end
    end

    describe "from:/to: overrides" do
      it "uses from: as the drive origin and labels travel_from accordingly" do
        evt = make_event(
          name: "Pickup detour",
          start_at: Time.zone.parse("2026-06-18 14:00"),
          end_at:   Time.zone.parse("2026-06-18 15:00"),
          location: "Office",
          notes:    "from:Gym",
        )
        described_class.new(user, Date.new(2026, 6, 18)).run

        meta = evt.reload.metadata["travel"]
        expect(meta["travel_from"]).to eq("Gym")
        expect(meta["travel_from_kind"]).to eq("override")
        expect(meta["travel_seconds"]).to eq(600)  # Gym→Office, not Home St→Office
        expect(meta["overrides"]["from"]).to eq("Gym")
      end

      it "treats to: as a POST-event leg from event location → to: destination" do
        evt = make_event(
          name: "Leave",
          start_at: Time.zone.parse("2026-06-18 14:00"),
          end_at:   Time.zone.parse("2026-06-18 15:00"),
          location: "Office",
          notes:    "to:Gym",
        )
        described_class.new(user, Date.new(2026, 6, 18)).run

        meta = evt.reload.metadata["travel"]
        # Incoming = Home St → Office (default 600s); `to:` no longer
        # overrides the incoming destination.
        expect(meta["travel_seconds"]).to eq(600)
        # Post-event = Office → Gym (600s), arriving at end_at + 600s.
        expect(meta["post_travel_to"]).to eq("Gym")
        expect(meta["post_travel_seconds"]).to eq(600)
        expect(meta["post_travel_minutes"]).to eq(10)
        expect(meta["post_arrive_at"]).to eq(evt.end_at.to_i + 600)
        expect(meta["overrides"]["to"]).to eq("Gym")
      end

      it "combines from: (incoming origin) and to: (outgoing endpoint) independently" do
        evt = make_event(
          name: "Explicit nav",
          start_at: Time.zone.parse("2026-06-18 14:00"),
          end_at:   Time.zone.parse("2026-06-18 15:00"),
          location: "Office",
          notes:    "from:Gym\nto:Gym",
        )
        described_class.new(user, Date.new(2026, 6, 18)).run

        meta = evt.reload.metadata["travel"]
        # Incoming = Gym → Office (600s) — from: overrides origin only.
        expect(meta["travel_seconds"]).to eq(600)
        expect(meta["travel_from"]).to eq("Gym")
        expect(meta["travel_from_kind"]).to eq("override")
        # Post-event = Office → Gym (600s).
        expect(meta["post_travel_seconds"]).to eq(600)
        expect(meta["post_travel_to"]).to eq("Gym")
      end

      it "short-circuits incoming drive to 0 when from: matches the event's location" do
        evt = make_event(
          name: "Return Home",
          start_at: Time.zone.parse("2026-06-18 20:00"),
          end_at:   Time.zone.parse("2026-06-18 21:00"),
          location: "Greens Lake Campground",
          notes:    "from:Greens Lake Campground\nto:Home St",
        )
        # Fail the spec if resolver gets called for the no-op leg.
        expect(address_book).not_to receive(:traveltime_seconds).with("Greens Lake Campground", "Greens Lake Campground", anything)
        described_class.new(user, Date.new(2026, 6, 18)).run

        meta = evt.reload.metadata["travel"]
        expect(meta["travel_seconds"]).to eq(0)
        expect(meta["travel_minutes"]).to eq(0)
        expect(meta["travel_from"]).to eq("Greens Lake Campground")
        expect(meta["travel_from_kind"]).to eq("override")
      end

      it "short-circuits post-travel to 0 when to: matches the event's location" do
        evt = make_event(
          name: "Stay put",
          start_at: Time.zone.parse("2026-06-18 14:00"),
          end_at:   Time.zone.parse("2026-06-18 15:00"),
          location: "Greens Lake Campground",
          notes:    "to:greens lake campground",  # case-insensitive match
        )
        expect(address_book).not_to receive(:traveltime_seconds).with("greens lake campground", "Greens Lake Campground", anything)
        described_class.new(user, Date.new(2026, 6, 18)).run

        meta = evt.reload.metadata["travel"]
        expect(meta["post_travel_seconds"]).to eq(0)
        expect(meta["post_travel_minutes"]).to eq(0)
      end

      it "leaves post_travel_* nil when no to: override is set" do
        evt = make_event(
          name: "No outbound",
          start_at: Time.zone.parse("2026-06-18 14:00"),
          end_at:   Time.zone.parse("2026-06-18 15:00"),
          location: "Office",
        )
        described_class.new(user, Date.new(2026, 6, 18)).run

        meta = evt.reload.metadata["travel"]
        expect(meta["post_travel_to"]).to be_nil
        expect(meta["post_travel_seconds"]).to be_nil
        expect(meta["post_arrive_at"]).to be_nil
      end

      it "breaks the travel chain when a successor declares an explicit from:" do
        a = make_event(
          name: "Meeting A",
          start_at: Time.zone.parse("2026-06-18 14:00"),
          end_at:   Time.zone.parse("2026-06-18 15:00"),
          location: "Office",
        )
        b = make_event(
          name: "Workout",
          start_at: Time.zone.parse("2026-06-18 15:15"),
          end_at:   Time.zone.parse("2026-06-18 16:15"),
          location: "Gym",
          notes:    "from:Home St",  # explicit — break chain even though gap is tight
        )
        described_class.new(user, Date.new(2026, 6, 18)).run

        a_meta = a.reload.metadata["travel"]
        b_meta = b.reload.metadata["travel"]
        expect(a_meta["chain_successor_id"]).to be_nil
        expect(b_meta["chain_predecessor_id"]).to be_nil
        expect(b_meta["travel_from_kind"]).to eq("override")
        expect(b_meta["travel_from"]).to eq("Home St")
      end

      it "uses before: as the incoming first stop independent of to:" do
        evt = make_event(
          name: "Stop first",
          start_at: Time.zone.parse("2026-06-18 14:00"),
          end_at:   Time.zone.parse("2026-06-18 15:00"),
          location: "Home St",
          notes:    "before:Gym\nto:Far",
        )
        described_class.new(user, Date.new(2026, 6, 18)).run

        meta = evt.reload.metadata["travel"]
        # Incoming = Home St → first before-waypoint (Gym) = 1200s.
        expect(meta["travel_seconds"]).to eq(1200)
        # Post-event = Home St → to:Far = 7200s.
        expect(meta["post_travel_seconds"]).to eq(7200)
        expect(meta["post_travel_to"]).to eq("Far")
      end
    end

    describe "schedule write-through" do
      it "mirrors an item's chain-computed travel onto its parent schedule" do
        schedule = create(:agenda_schedule, agenda: agenda, name: "TMS", start_time: "14:00",
          duration_minutes: 60, recurrence: { freq: "weekdays" },
          starts_on: Date.parse("2026-06-01"))
        schedule.update_columns(metadata: {})
        # Wipe any auto-materialized rows so this test owns the items.
        schedule.agenda_items.delete_all

        evt = agenda.agenda_items.create!(
          agenda_schedule: schedule,
          name: "TMS", kind: :event, location: "Office",
          start_at: Time.zone.parse("2026-06-22 14:00"),
          end_at:   Time.zone.parse("2026-06-22 15:00"),
        )
        described_class.new(user, Date.new(2026, 6, 22)).run

        schedule.reload
        sched_travel = schedule.metadata["travel"]
        expect(sched_travel["travel_minutes"]).to eq(10)
        expect(sched_travel["travel_seconds"]).to eq(600)
        expect(sched_travel["travel_from"]).to eq("Home St")
        # Chain pointers and `leave_at` are item-specific — must NOT leak.
        expect(sched_travel).not_to have_key("chain_predecessor_id")
        expect(sched_travel).not_to have_key("leave_at")
      end

      it "does nothing for standalone items with no parent schedule" do
        evt = make_event(name: "Standalone", start_at: Time.zone.parse("2026-06-22 14:00"),
          end_at: Time.zone.parse("2026-06-22 15:00"), location: "Office")
        described_class.new(user, Date.new(2026, 6, 22)).run

        expect(evt.reload.metadata.dig("travel", "travel_minutes")).to eq(10)
        # No raise — schedule is nil.
      end
    end

    describe "to: post-travel and chain detection" do
      it "chains A → B when A has to:X and B follows tightly via X" do
        # A: 14:00-15:00 at Home St, to:Office. Via Office, drive to B's
        # location (Gym) is 600s. B starts 15:05 at Gym — the gap
        # (14:55 leave-by) is BEFORE A's end + via-drive (15:10), so chain.
        a = make_event(
          name: "Leave",
          start_at: Time.zone.parse("2026-06-18 14:00"),
          end_at:   Time.zone.parse("2026-06-18 15:00"),
          location: "Home St",
          notes:    "to:Office",
        )
        b = make_event(
          name: "Arrive",
          start_at: Time.zone.parse("2026-06-18 15:05"),
          end_at:   Time.zone.parse("2026-06-18 16:00"),
          location: "Gym",
        )
        described_class.new(user, Date.new(2026, 6, 18)).run

        a_meta = a.reload.metadata["travel"]
        b_meta = b.reload.metadata["travel"]
        expect(a_meta["chain_successor_id"]).to eq(b.id)
        expect(b_meta["chain_predecessor_id"]).to eq(a.id)
      end

      it "does not chain when the via-to: route fits within the gap" do
        # A ends 12:00, to:Office. B starts 16:00 at Gym — plenty of slack.
        a = make_event(
          name: "Meeting",
          start_at: Time.zone.parse("2026-06-18 11:00"),
          end_at:   Time.zone.parse("2026-06-18 12:00"),
          location: "Home St",
          notes:    "to:Office",
        )
        b = make_event(
          name: "Workout",
          start_at: Time.zone.parse("2026-06-18 16:00"),
          end_at:   Time.zone.parse("2026-06-18 17:00"),
          location: "Gym",
        )
        described_class.new(user, Date.new(2026, 6, 18)).run

        a_meta = a.reload.metadata["travel"]
        b_meta = b.reload.metadata["travel"]
        expect(a_meta["chain_successor_id"]).to be_nil
        expect(b_meta["chain_predecessor_id"]).to be_nil
      end
    end

    it "uses after: list's last entry as the outgoing location for next chain decision" do
      a = make_event(
        name: "A",
        start_at: Time.zone.parse("2026-06-18 14:00"),
        end_at:   Time.zone.parse("2026-06-18 15:00"),
        location: "Office",
        notes:    "after:Gym",
      )
      b = make_event(
        name: "B",
        start_at: Time.zone.parse("2026-06-18 16:00"),
        end_at:   Time.zone.parse("2026-06-18 17:00"),
        location: "Office",
      )
      described_class.new(user, Date.new(2026, 6, 18)).run

      # Chain decision compares Gym→Home vs leaving for B from Home.
      # Gym→Home is 1200s = 20m, A ends 15:00, so user can be home at 15:20.
      # B leave time = 16:00 - Home→Office (600s = 10m) = 15:50. Plenty of room.
      # So chain should NOT form.
      a_meta = a.reload.metadata["travel"]
      expect(a_meta["chain_successor_id"]).to be_nil
    end
  end
end
