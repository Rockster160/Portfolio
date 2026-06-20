require "rails_helper"

# ONE-SHOT: validates + behavior-tests the new code for tasks 391 + 392
# ("Agenda Travel Go" and "Agenda Travel Nav Home") before the prodExec
# script runs. DELETE THIS FILE post-deploy.
#
# Task 391 Go — title "Time to go!", body "Xm drive to <location>".
# Task 392 Nav Home:
#   • Starts climate + navigates Home AND pings "Drive home / It will
#     take Xm to get home".
#   • Skips when the event is a chain MIDDLE (chain_successor_id present),
#     because the next event's prepare trigger is what should be driving
#     the car's navigation.
#   • Falls back to start + nav + ping with 0m when there is no `id` in
#     the payload (defensive — pre-deploy scheduled_triggers).
RSpec.describe "Agenda Travel Go + Nav Home (tasks 391 + 392)" do
  let(:user) { User.me }
  let(:ctrl) { instance_double(::TeslaControl) }

  GO_CODE = <<~'JIL'.freeze
    *input = Global.input_data()::Hash
    i_splat = input.splat({
      e_name = Keyword.ItemKey("e_name")::String
      travel_minutes = Keyword.ItemKey("travel_minutes")::Numeric
      e_location = Keyword.ItemKey("e_location")::String
    })::Hash
    goTitle = String.new("Time to go!")::String
    goBody = String.new("#{travel_minutes}m drive to #{e_location}")::String
    pingText = String.new("#{goTitle}\n#{goBody}")::String
    sent = Global.ping(pingText)::String
  JIL

  NAV_HOME_CODE = <<~'JIL'.freeze
    *input = Global.input_data()::Hash
    itemId = input.get("id")::Numeric
    hasId = Boolean.compare(itemId, ">", 0)::Boolean
    state = Global.if({
      hasIdCond = Global.ref(hasId)::Boolean
    }, {
      idHash = Hash.new({
        i1 = Keyval.new("id", itemId)::Keyval
      })::Hash
      evt = Global.ref(idHash)::AgendaItem
      meta = evt.metadata()::Hash
      travel = meta.get("travel")::Hash
      succId = travel.get("chain_successor_id")::Numeric
      tMin = travel.get("travel_minutes")::Numeric
      withId = Hash.new({
        s1 = Keyval.new("succ", succId)::Keyval
        s2 = Keyval.new("min", tMin)::Keyval
      })::Hash
    }, {
      noId = Hash.new({
        n1 = Keyval.new("succ", 0)::Keyval
        n2 = Keyval.new("min", 0)::Keyval
      })::Hash
    })::Hash
    succ = state.get("succ")::Numeric
    homeMin = state.get("min")::Numeric
    isMid = Boolean.compare(succ, ">", 0)::Boolean
    navBranch = Global.if({
      isMidCond = Global.ref(isMid)::Boolean
    }, {
      noopMid = Boolean.new(true)::Boolean
    }, {
      homeTitle = String.new("Drive home")::String
      homeBody = String.new("It will take #{homeMin}m to get home")::String
      pingText = String.new("#{homeTitle}\n#{homeBody}")::String
      sent = Global.ping(pingText)::String
      started = Tesla.start({
        navHome = TeslaStartOptions.navigate("Home")::Hash
      })::Boolean
    })::Any
  JIL

  before do
    allow(::TeslaControl).to receive(:me).and_return(ctrl)
    # The AgendaItem after_save enqueues a chain sync that hits Google's
    # geocode endpoint; we set the chain metadata directly so the sync
    # adds nothing — stub the worker out entirely for these specs.
    allow(::AgendaTravelChainSyncWorker).to receive(:perform_async).and_return(nil)
    allow(::AgendaTravelChainSyncWorker).to receive(:new).and_return(double(perform: nil))
  end

  describe "Go (task 391)" do
    it "validates" do
      Jil::Validator.validate!(GO_CODE)
    end

    it "pings 'Time to go!' as title and 'Xm drive to <location>' as body" do
      pings = []
      allow_any_instance_of(Jil::Methods::Global).to receive(:ping) { |_, msg|
        pings << msg
        msg.to_s
      }

      ::Jil::Executor.call(user, GO_CODE, {
        "e_name"         => "Doctor",
        "travel_minutes" => 25,
        "e_location"     => "Acme Clinic",
      })

      expect(pings.size).to eq(1)
      expect(pings.first).to eq("Time to go!\n25m drive to Acme Clinic")
    end
  end

  describe "Nav Home (task 392)" do
    it "validates" do
      Jil::Validator.validate!(NAV_HOME_CODE)
    end

    it "pings 'Drive home / It will take Xm to get home' and starts car + navs Home for a solo event" do
      agenda = user.agendas.first || create(:agenda, user: user, name: "Test")
      evt = agenda.agenda_items.create!(
        kind:     :event,
        name:     "Solo event",
        start_at: 1.hour.from_now,
        end_at:   2.hours.from_now,
        location: "Costco",
        metadata: { "travel" => { "chain_successor_id" => nil, "travel_minutes" => 22 } },
      )

      pings = []
      allow_any_instance_of(Jil::Methods::Global).to receive(:ping) { |_, msg|
        pings << msg
        msg.to_s
      }

      expect(ctrl).to receive(:start_car)
      expect(ctrl).to receive(:navigate).with("Home")

      jil = ::Jil::Executor.call(user, NAV_HOME_CODE, { "id" => evt.id })
      expect(jil.ctx[:error]).to be_nil
      expect(pings).to eq(["Drive home\nIt will take 22m to get home"])
    end

    it "no-ops entirely (no ping, no car) for a chain-middle event" do
      agenda = user.agendas.first || create(:agenda, user: user, name: "Test")
      evt = agenda.agenda_items.create!(
        kind:     :event,
        name:     "Chain middle",
        start_at: 1.hour.from_now,
        end_at:   2.hours.from_now,
        location: "Costco",
        metadata: { "travel" => { "chain_successor_id" => 999, "travel_minutes" => 18 } },
      )

      pings = []
      allow_any_instance_of(Jil::Methods::Global).to receive(:ping) { |_, msg|
        pings << msg
        msg.to_s
      }

      expect(ctrl).not_to receive(:start_car)
      expect(ctrl).not_to receive(:navigate)

      jil = ::Jil::Executor.call(user, NAV_HOME_CODE, { "id" => evt.id })
      expect(jil.ctx[:error]).to be_nil
      expect(pings).to be_empty
    end

    it "still pings + nav-Home when no id is in the payload (legacy fallback, 0m body)" do
      pings = []
      allow_any_instance_of(Jil::Methods::Global).to receive(:ping) { |_, msg|
        pings << msg
        msg.to_s
      }

      expect(ctrl).to receive(:start_car)
      expect(ctrl).to receive(:navigate).with("Home")

      jil = ::Jil::Executor.call(user, NAV_HOME_CODE, { "e_name" => "Legacy" })
      expect(jil.ctx[:error]).to be_nil
      expect(pings).to eq(["Drive home\nIt will take 0m to get home"])
    end
  end

  # Validate the surgical sub the prodExec script applies to task 388's
  # payloadHome block. We pin the regex against the real on-disk code so
  # an upstream refactor of task 388 breaks here instead of in prod.
  it "task 388 payloadHome substitution adds the id keyval" do
    old_code = <<~'JIL'
      payloadHome = Hash.new({
        ph1 = Keyval.new("e_name", evtName)::Keyval
      })::Hash
    JIL

    new_code = old_code.sub(
      /(payloadHome = Hash\.new\(\{\n\s*ph1 = Keyval\.new\("e_name", evtName\)::Keyval)\n(\s*)(\}\)::Hash)/,
      "\\1\n\\2  ph2 = Keyval.new(\"id\", evtId)::Keyval\n\\2\\3",
    )

    expect(new_code).not_to eq(old_code)
    expect(new_code).to include(%(ph2 = Keyval.new("id", evtId)::Keyval))
  end
end
