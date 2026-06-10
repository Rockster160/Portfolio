require "rails_helper"

RSpec.describe "Jarvis: Agenda Add with future time bias" do
  let(:user) { User.me }

  let(:code) do
    <<~'JIL'
      data = Global.input_data()::Hash
      captures = data.get("named_captures")::Hash
      itemName = captures.get("name")::String
      phrase = data.get("full")::String
      ts = Date.parse(phrase, "future")::Date
      created = Agenda.add_task("Rockster160", itemName, ts)::AgendaItem
      msg = Text.new("Added agenda item: #{itemName}")::String
      stop = Global.stop_propagation()::Any
      out = Global.return(msg)::Any
    JIL
  end

  it "validates" do
    expect { Jil::Validator.validate!(code) }.not_to raise_error
  end

  describe "behavior" do
    let!(:agenda) { Agenda.find_by(user: user, name: "Rockster160") || Agenda.create!(user: user, name: "Rockster160") }

    around { |ex| Time.use_zone("Mountain Time (US & Canada)") { ex.run } }

    it "rolls 'at 8:30am' said late at night into tomorrow morning" do
      Timecop.freeze(Time.zone.local(2026, 6, 9, 23, 57)) do
        input = {
          full:            "Agenda add Berry Breakfast at 8:30am",
          words:           "Agenda add Berry Breakfast",
          has_time:        true,
          timestamp:       "2026-06-09T08:30:00-06:00",
          named_captures: { name: "Berry Breakfast" },
        }
        expect { Jil::Executor.call(user, code, input) }
          .to change { agenda.reload.agenda_items.count }.by(1)

        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.name).to eq("Berry Breakfast")
        expect(item.start_at).to be > Time.current
        expect(item.start_at.in_time_zone(user.timezone).to_date).to eq(Date.new(2026, 6, 10))
        expect(item.start_at.in_time_zone(user.timezone).hour).to eq(8)
        expect(item.start_at.in_time_zone(user.timezone).min).to eq(30)
      end
    end

    it "falls back to Time.current when phrase has no time" do
      Timecop.freeze(Time.zone.local(2026, 6, 9, 23, 57)) do
        input = {
          full:            "agenda add Shower",
          words:           "agenda add Shower",
          timestamp:       "2026-06-09T23:57:00-06:00",
          named_captures: { name: "Shower" },
        }
        Jil::Executor.call(user, code, input)
        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.name).to eq("Shower")
        local = item.start_at.in_time_zone(user.timezone)
        expect(local.to_date).to eq(Date.new(2026, 6, 9))
        expect(local.hour).to eq(23)
        expect(local.min).to eq(57)
      end
    end

    it "leaves explicit future dates untouched (Aug 14)" do
      Timecop.freeze(Time.zone.local(2026, 6, 1, 22, 4)) do
        input = {
          full:            "Agenda add Eye thing Aug 14 at 3:10",
          words:           "Agenda add Eye thing",
          has_time:        true,
          timestamp:       "2026-08-14T15:10:00-06:00",
          named_captures: { name: "Eye thing" },
        }
        Jil::Executor.call(user, code, input)
        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.start_at.in_time_zone(user.timezone).to_date).to eq(Date.new(2026, 8, 14))
        expect(item.start_at.in_time_zone(user.timezone).hour).to eq(15)
      end
    end
  end
end
