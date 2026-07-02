require "rails_helper"

RSpec.describe Jil::Methods::AgendaSchedule, "#update! metadata merge" do
  before do
    allow(::AgendaTravelChainSyncWorker).to receive(:perform_async)
    allow(::Jil).to receive(:trigger)
  end

  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }
  let(:schedule) {
    create(:agenda_schedule,
      agenda: agenda,
      kind: :task,
      recurrence: { "freq" => "daily" },
      starts_on: Date.current,
      metadata: {
        "travel" => {
          "travel_minutes"       => 25,
          "location_fingerprint" => "abc123",
        },
        "other" => 1,
      })
  }

  it "deep-merges nested metadata rather than replacing" do
    code = <<~'JIL'
      *input = Global.input_data()::Hash
      schedId = input.get("id")::Numeric
      idHash = Hash.new({
        i1 = Keyval.new("id", schedId)::Keyval
      })::Hash
      sched = Global.ref(idHash)::AgendaSchedule
      tk = Hash.new({
        k1 = Keyval.new("travel_minutes", 12)::Keyval
      })::Hash
      te = Hash.new({
        t1 = Keyval.new("travel", tk)::Keyval
      })::Hash
      updated = sched.update!({
        mu = AgendaScheduleData.metadata(te)::Hash
      })::AgendaSchedule
    JIL
    ::Jil::Executor.call(user, code, { id: schedule.id })
    schedule.reload

    travel = schedule.metadata.fetch("travel")
    expect(travel["travel_minutes"]).to eq(12)
    expect(travel["location_fingerprint"]).to eq("abc123")
    expect(schedule.metadata["other"]).to eq(1)
  end
end
