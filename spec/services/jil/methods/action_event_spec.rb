RSpec.describe Jil::Methods::ActionEvent do
  include ActiveJob::TestHelper
  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.create(role: :admin, username: :admin, password: :password, password_confirmation: :password) }
  let(:code) {
    <<-JIL
      q9693 = ActionEvent.find("")::ActionEvent
      gd1cb = ActionEvent.search("", 50, "", "ASC")::Array
      f065c = ActionEvent.add("asdf", "asdf", "", "")::ActionEvent
    JIL
  }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  context "#find" do
    let(:code) { "q9693 = ActionEvent.find(\"#{event.id}\")::ActionEvent" }
    let(:event) { user.action_events.create(name: "Food", notes: "Dinner", data: { Calories: 400 }) }

    it "returns the found event" do
      expect_successful_jil

      ts = ctx.dig(:vars, :q9693, :value, "timestamp")
      expect(ctx.dig(:vars)).to match_hash({
        q9693: {
          class: :ActionEvent,
          value: {
            id: event.id,
            name: "Food",
            timestamp: ts,
            notes: "Dinner",
            data: { Calories: 400 },
          },
        },
      })
      expect(ctx[:output]).to eq([])
    end
  end

  context "#search" do
    # let(:code) { "gd1cb = ActionEvent.search(\"foo\", 50, \"\", \"ASC\")::Array" }
    # let!(:event) { user.action_events.create(name: "Food", notes: "Dinner", data: { Calories: 400 }) }
    #
    # it "returns the found event" do
    #   expect_successful_jil
    #
    #   expect(ctx.dig(:vars, :gd1cb, :class)).to eq(:Array)
    #   expect(ctx.dig(:vars, :gd1cb, :value).length).to eq(1)
    #   expect(ctx.dig(:vars, :gd1cb, :value, 0, "id")).to eq(event.id)
    #   expect(ctx[:output]).to eq([])
    # end
  end

  context "#add" do
    let(:code) { "q9693 = ActionEvent.add(\"Food\", \"Dinner\", \"\", \"\")::ActionEvent" }

    it "returns the found event" do
      expect_successful_jil

      ts = ctx.dig(:vars, :q9693, :value, "timestamp")
      id = ctx.dig(:vars, :q9693, :value, "id")
      expect(DateTime.parse(ts).to_i).to be_within(5).of(::Time.current.to_i)
      expect(ctx.dig(:vars)).to match_hash({
        q9693: {
          class: :ActionEvent,
          value: {
            id: id,
            name: "Food",
            timestamp: ts,
            notes: "Dinner",
            data: {},
          },
        },
      })
      expect(ctx[:output]).to eq([])
    end
  end
end
