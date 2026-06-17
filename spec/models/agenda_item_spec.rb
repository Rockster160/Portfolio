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
end
