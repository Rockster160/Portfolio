require "rails_helper"

RSpec.describe Jil::Methods::AgendaItem, "#update! metadata merge" do
  before do
    allow(::AgendaTravelChainSyncWorker).to receive(:perform_async)
    allow(::Jil).to receive(:trigger)
  end

  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }
  let(:item) {
    create(:agenda_item,
      agenda: agenda,
      kind: :event,
      start_at: Time.zone.local(2026, 7, 3, 14, 0),
      end_at:   Time.zone.local(2026, 7, 3, 15, 0),
      location: "Somewhere",
      metadata: {
        "travel" => {
          "travel_minutes"       => 25,
          "chain_predecessor_id" => 42,
          "leave_at"             => 111_111,
        },
        "other_writer" => { "flag" => true },
      })
  }

  def run_jil(code, item_id: item.id)
    ::Jil::Executor.call(user, code, { id: item_id })
  end

  it "deep-merges a nested metadata write instead of replacing" do
    code = <<~'JIL'
      *input = Global.input_data()::Hash
      itemId = input.get("id")::Numeric
      idHash = Hash.new({
        i1 = Keyval.new("id", itemId)::Keyval
      })::Hash
      evt = Global.ref(idHash)::AgendaItem
      travelKeys = Hash.new({
        tk1 = Keyval.new("travel_minutes", 23)::Keyval
      })::Hash
      travelEntry = Hash.new({
        te1 = Keyval.new("travel", travelKeys)::Keyval
      })::Hash
      updated = evt.update!({
        mu = AgendaItemData.metadata(travelEntry)::Hash
      })::AgendaItem
    JIL
    run_jil(code)
    item.reload

    travel = item.metadata.fetch("travel")
    expect(travel["travel_minutes"]).to eq(23)
    expect(travel["chain_predecessor_id"]).to eq(42)
    expect(travel["leave_at"]).to eq(111_111)
    expect(item.metadata.fetch("other_writer")).to eq("flag" => true)
  end

  it "preserves unrelated top-level keys when writing a top-level key" do
    code = <<~'JIL'
      *input = Global.input_data()::Hash
      itemId = input.get("id")::Numeric
      idHash = Hash.new({
        i1 = Keyval.new("id", itemId)::Keyval
      })::Hash
      evt = Global.ref(idHash)::AgendaItem
      topKeys = Hash.new({
        tk1 = Keyval.new("legacy_travel_minutes", 23)::Keyval
      })::Hash
      updated = evt.update!({
        mu = AgendaItemData.metadata(topKeys)::Hash
      })::AgendaItem
    JIL
    run_jil(code)
    item.reload

    expect(item.metadata["legacy_travel_minutes"]).to eq(23)
    expect(item.metadata.dig("travel", "chain_predecessor_id")).to eq(42)
    expect(item.metadata.dig("other_writer", "flag")).to be true
  end

  it "handles items whose metadata starts empty" do
    empty_item = create(:agenda_item,
      agenda: agenda,
      kind: :event,
      start_at: Time.zone.local(2026, 7, 3, 16, 0),
      end_at:   Time.zone.local(2026, 7, 3, 17, 0),
      location: "Elsewhere",
      metadata: {})
    code = <<~'JIL'
      *input = Global.input_data()::Hash
      itemId = input.get("id")::Numeric
      idHash = Hash.new({
        i1 = Keyval.new("id", itemId)::Keyval
      })::Hash
      evt = Global.ref(idHash)::AgendaItem
      travelKeys = Hash.new({
        tk1 = Keyval.new("travel_minutes", 12)::Keyval
      })::Hash
      travelEntry = Hash.new({
        te1 = Keyval.new("travel", travelKeys)::Keyval
      })::Hash
      updated = evt.update!({
        mu = AgendaItemData.metadata(travelEntry)::Hash
      })::AgendaItem
    JIL
    run_jil(code, item_id: empty_item.id)
    empty_item.reload

    expect(empty_item.metadata.dig("travel", "travel_minutes")).to eq(12)
  end
end
