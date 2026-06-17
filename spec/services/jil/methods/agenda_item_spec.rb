RSpec.describe Jil::Methods::AgendaItem do
  let(:user) { User.me }
  let(:agenda) { user.agendas.first || create(:agenda, user: user) }
  let(:item) {
    create(
      :agenda_item, agenda: agenda, kind: "task",
      name: "Doctor", start_at: 1.hour.from_now, location: "123 Main St"
    )
  }
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:input_data) { { id: item.id } }
  let(:ctx) { execute.ctx }

  describe "#update! with metadata content block" do
    let(:code) {
      <<~JIL
        *evt = Global.input_data()::Hash
        meta = Hash.new({
          k1 = Keyval.new("travel_minutes", 25)::Keyval
          k2 = Keyval.new("travel_location", "123 Main St")::Keyval
        })::Hash
        updated = AgendaItem.update!(evt, {
          m = AgendaItemData.metadata(meta)::Hash
        })::AgendaItem
      JIL
    }

    it "persists the metadata hash on the AgendaItem" do
      expect_successful_jil
      expect(item.reload.metadata).to eq(
        "travel_minutes"  => 25,
        "travel_location" => "123 Main St",
      )
    end
  end

  describe "AgendaItem.metadata getter" do
    before { item.update!(metadata: { travel_minutes: 9 }) }

    let(:code) {
      <<~'JIL'
        *evt = Global.input_data()::Hash
        meta = evt.get("metadata")::Hash
        mins = meta.get("travel_minutes")::Numeric
        out = Global.ping("#{mins}")::String
      JIL
    }

    it "exposes metadata in the serialized hash that arrives via trigger" do
      input_data.merge!(item.reload.serialize)
      expect_successful_jil
      expect(ctx.dig(:vars, :mins, :value)).to eq(9)
    end
  end

  describe "#update! with arrive_early_minutes" do
    let(:code) {
      <<~JIL
        *evt = Global.input_data()::Hash
        updated = AgendaItem.update!(evt, {
          a = AgendaItemData.arrive_early_minutes(15)::Hash
        })::AgendaItem
      JIL
    }

    it "persists arrive_early_minutes on the AgendaItem" do
      expect_successful_jil
      expect(item.reload.arrive_early_minutes).to eq(15)
    end
  end

  describe "AgendaItem.arrive_early_minutes getter" do
    before { item.update!(arrive_early_minutes: 7) }

    let(:code) {
      <<~'JIL'
        *evt = Global.input_data()::Hash
        mins = evt.get("arrive_early_minutes")::Numeric
        out = Global.ping("#{mins}")::String
      JIL
    }

    it "exposes arrive_early_minutes in the serialized hash that arrives via trigger" do
      input_data.merge!(item.reload.serialize)
      expect_successful_jil
      expect(ctx.dig(:vars, :mins, :value)).to eq(7)
    end
  end
end
