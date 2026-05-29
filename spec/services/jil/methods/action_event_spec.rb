RSpec.describe Jil::Methods::ActionEvent do
  include ActiveJob::TestHelper

  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:code) {
    <<-JIL
      q9693 = ActionEvent.find("")::ActionEvent
      gd1cb = ActionEvent.search("", 50, "ASC")::Array
      f065c = ActionEvent.create({
        jd135 = ActionEventData.name("Title")::ActionEventData
        n2a70 = ActionEventData.notes("details")::ActionEventData
      })::ActionEvent
    JIL
  }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  describe "#find" do
    let(:code) { "q9693 = ActionEvent.find(\"#{event.id}\")::ActionEvent" }
    let(:event) { user.action_events.create(name: "Food", notes: "Dinner", data: { Calories: 400 }) }

    it "returns the found event" do
      expect_successful_jil

      found = ctx.dig(:vars, :q9693, :value)
      expect(found).to be_a(::ActionEvent)
      expect(found.id).to eq(event.id)
      expect(found.name).to eq("Food")
      expect(found.notes).to eq("Dinner")
      expect(found.data).to eq({ "Calories" => 400 })
      expect(ctx[:output]).to eq([])
    end
  end

  describe "#search" do
    let(:code) { "gd1cb = ActionEvent.search(\"foo\", 50, \"ASC\")::Array" }
    let!(:event) { user.action_events.create(name: "Food", notes: "Dinner", data: { Calories: 400 }) }

    it "returns the found event" do
      expect_successful_jil

      expect(ctx.dig(:vars, :gd1cb, :class)).to eq(:Array)
      expect(ctx.dig(:vars, :gd1cb, :value).length).to eq(1)
      expect(ctx.dig(:vars, :gd1cb, :value, 0, "id")).to eq(event.id)
      expect(ctx[:output]).to eq([])
    end

    context "with different search" do
      let(:code) { "gd1cb = ActionEvent.search(\"blah\", 50, \"ASC\")::Array" }

      it "does not return non-matches" do
        expect_successful_jil

        expect(ctx.dig(:vars, :gd1cb, :class)).to eq(:Array)
        expect(ctx.dig(:vars, :gd1cb, :value).length).to eq(0)
        expect(ctx[:output]).to eq([])
      end
    end
  end

  describe ".action (exposed via Jilable execution_attrs)" do
    let(:code) {
      <<~JIL
        act = Global.input_data()::ActionEvent
        actStr = act.action()::String
      JIL
    }

    it "exposes the trigger action symbol as a String to Jil" do
      event = user.action_events.create(name: "Wordle").with_jil_attrs(action: :added)
      ctx = Jil::Executor.call(user, code, event).ctx
      expect(ctx.dig(:vars, :actStr, :value)).to eq("added")
    end

    it "returns blank when no action attr was set" do
      event = user.action_events.create(name: "Bare")
      ctx = Jil::Executor.call(user, code, event).ctx
      expect(ctx.dig(:vars, :actStr, :value)).to be_blank
    end
  end

  describe "#add" do
    let(:code) { "q9693 = ActionEvent.add(\"Thing\")::ActionEvent" }

    it "returns the found event" do
      expect_successful_jil

      found = ctx.dig(:vars, :q9693, :value)
      expect(found).to be_a(::ActionEvent)
      expect(found.name).to eq("Thing")
      expect(found.timestamp.to_i).to be_within(5).of(::Time.current.to_i)
      expect(found.notes).to be_nil
      expect(found.data).to be_nil
      expect(ctx[:output]).to eq([])
    end
  end

  describe "#create" do
    let(:code) {
      <<-JIL
        q9693 = ActionEvent.create({
          jd135 = ActionEventData.name("Food")::ActionEventData
          n2a70 = ActionEventData.notes("Dinner")::ActionEventData
        })::ActionEvent
      JIL
    }

    it "returns the found event" do
      expect_successful_jil

      found = ctx.dig(:vars, :q9693, :value)
      expect(found).to be_a(::ActionEvent)
      expect(found.name).to eq("Food")
      expect(found.notes).to eq("Dinner")
      expect(found.timestamp.to_i).to be_within(5).of(::Time.current.to_i)
      expect(found.data).to be_nil
      expect(ctx[:output]).to eq([])
    end
  end

  describe "#bulk_destroy" do
    let!(:inside_old_1) { user.action_events.create(name: "Whisper", notes: "Inside", timestamp: 8.days.ago) }
    let!(:inside_old_2) { user.action_events.create(name: "Whisper", notes: "Inside", timestamp: 10.days.ago) }
    let!(:outside_old) { user.action_events.create(name: "Whisper", notes: "Outside", timestamp: 9.days.ago) }
    let!(:whisper_recent) { user.action_events.create(name: "Whisper", notes: "Inside", timestamp: 1.day.ago) }
    let!(:other_event) { user.action_events.create(name: "Food", notes: "Dinner") }
    let(:cutoff) { 7.days.ago.strftime("%Y-%m-%d") }
    let(:code) {
      <<-JIL
        count = ActionEvent.bulk_destroy("name::Whisper notes::Inside timestamp<'#{cutoff}'", 1000)::Numeric
      JIL
    }

    it "deletes matching events and returns the count" do
      expect_successful_jil

      expect(ctx.dig(:vars, :count, :class)).to eq(:Numeric)
      expect(ctx.dig(:vars, :count, :value)).to eq(2)
      expect(::ActionEvent.where(id: [inside_old_1.id, inside_old_2.id])).to be_empty
      expect(::ActionEvent.where(id: [outside_old.id, whisper_recent.id, other_event.id]).count).to eq(3)
    end

    it "does not enqueue per-event broadcast workers" do
      expect {
        expect_successful_jil
      }.not_to have_enqueued_job(ActionEventBroadcastWorker)
    end

    it "does not fire Jil event triggers for each deletion" do
      expect(::Jil).not_to receive(:trigger).with(anything, :event, anything, any_args)
      expect_successful_jil
    end

    context "when limit caps the deletion" do
      let(:code) { "count = ActionEvent.bulk_destroy(\"name::Whisper notes::Inside timestamp<'#{cutoff}'\", 1)::Numeric" }

      it "deletes only up to limit" do
        expect_successful_jil

        expect(ctx.dig(:vars, :count, :value)).to eq(1)
        remaining = ::ActionEvent
          .where(user: user, name: "Whisper", notes: "Inside")
          .where("timestamp < ?", 7.days.ago)
          .count
        expect(remaining).to eq(1)
      end
    end
  end

  describe "#bulk_update" do
    let!(:e1) { user.action_events.create(name: "Whisper", notes: "Inside", timestamp: 8.days.ago) }
    let!(:e2) { user.action_events.create(name: "Whisper", notes: "Inside", timestamp: 9.days.ago) }
    let!(:other) { user.action_events.create(name: "Food", notes: "Inside") }
    let(:code) {
      <<-JIL
        count = ActionEvent.bulk_update("name::Whisper notes::Inside", 1000, {
          nd1 = ActionEventData.notes("Archived")::ActionEventData
        })::Numeric
      JIL
    }

    it "updates matching events and returns the count" do
      expect_successful_jil

      expect(ctx.dig(:vars, :count, :value)).to eq(2)
      expect(e1.reload.notes).to eq("Archived")
      expect(e2.reload.notes).to eq("Archived")
      expect(other.reload.notes).to eq("Inside")
    end

    it "does not enqueue per-event broadcast workers" do
      expect {
        expect_successful_jil
      }.not_to have_enqueued_job(ActionEventBroadcastWorker)
    end
  end

  context "parsing" do
    let!(:evt) { ActionEvent.create(user: user, name: "Drink", notes: "Coke") }
    let!(:new_evt) { ActionEvent.create(user: user, name: "Drink", notes: "Coke") }
    let(:code) {
      <<-JIL
        name = String.new("Drink")::String
        notes = String.new("Coke")::String
        id = Numeric.new(#{evt.id})::Numeric
        evts = ActionEvent.search("name::\\"\#{name}\\" notes::\\"\#{notes}\\" id!::\#{id}", 5, "DESC")::Array
      JIL
    }

    it "properly executes the search" do
      expect_successful_jil

      evts = ctx.dig(:vars, :evts, :value)
      expect(evts.length).to eq(1)
      expect(evts.dig(0, :id)).to eq(new_evt.id)
    end
  end
end
