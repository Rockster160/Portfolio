require "rails_helper"

# Covers the Jil ↔ Tesla integration end-to-end: the TeslaStartOptions
# content-block builders are declared in schema.txt but had no Ruby class
# wired up, so every `Tesla.start({...})` task failed silently at runtime
# with "Class does not exist: TeslaStartOptions". These specs pin both the
# builder routing and Tesla.start's array-of-hashes merge semantics.
RSpec.describe "Jil Tesla integration" do
  let(:user) { User.me }
  let(:ctrl) { instance_double(::TeslaControl) }

  before do
    allow(::TeslaControl).to receive(:me).and_return(ctrl)
    # The wrapper consults TripState.car_at? on any nav destination —
    # stub false so these specs exercise the normal-flow branch, not
    # the "already at destination" short-circuit.
    allow(::TripState).to receive(:car_at?).and_return(false)
    allow(::TripState).to receive(:start_for_destination!)
    allow(::WebPushNotifications).to receive(:send_to)
  end

  it "Tesla.start with a single TeslaStartOptions.navigate routes through TeslaControl" do
    expect(ctrl).to receive(:start_car)
    expect(ctrl).to receive(:navigate).with("Bedrock 1234 Some St")

    code = <<~'JIL'
      started = Tesla.start({
        tso1 = TeslaStartOptions.navigate("Bedrock 1234 Some St")::Hash
      })::Boolean
    JIL
    Jil::Validator.validate!(code)
    jil = ::Jil::Executor.call(user, code, {})
    expect(jil.ctx[:error]).to be_nil
    expect(jil.ctx[:vars][:started][:value]).to be(true)
  end

  it "Tesla.start merges multiple TeslaStartOptions builders" do
    expect(ctrl).to receive(:start_car)
    expect(ctrl).to receive(:set_temp).with(70.0)
    expect(ctrl).to receive(:navigate).with("Home")
    expect(ctrl).to receive(:heat_driver)
    expect(ctrl).to receive(:windows).with(:open)

    code = <<~'JIL'
      started = Tesla.start({
        tso1 = TeslaStartOptions.navigate("Home")::Hash
        tso2 = TeslaStartOptions.temp(70)::Hash
        tso3 = TeslaStartOptions.heatDriver(true)::Hash
        tso4 = TeslaStartOptions.vent(true)::Hash
      })::Boolean
    JIL
    Jil::Validator.validate!(code)
    jil = ::Jil::Executor.call(user, code, {})
    expect(jil.ctx[:error]).to be_nil
    expect(jil.ctx[:vars][:started][:value]).to be(true)
  end

  it "Tesla.start with an empty content block still kicks climate on" do
    expect(ctrl).to receive(:start_car)

    code = <<~'JIL'
      started = Tesla.start({})::Boolean
    JIL
    Jil::Validator.validate!(code)
    jil = ::Jil::Executor.call(user, code, {})
    expect(jil.ctx[:error]).to be_nil
    expect(jil.ctx[:vars][:started][:value]).to be(true)
  end

  it "Tesla.navigate as a direct action routes through TeslaControl" do
    expect(ctrl).to receive(:navigate).with("Home")

    code = <<~'JIL'
      nav = Tesla.navigate("Home")::Boolean
    JIL
    Jil::Validator.validate!(code)
    jil = ::Jil::Executor.call(user, code, {})
    expect(jil.ctx[:error]).to be_nil
    expect(jil.ctx[:vars][:nav][:value]).to be(true)
  end

  it "Tesla.addStop routes through TeslaControl#add_stop" do
    expect(ctrl).to receive(:add_stop).with("Costco").and_return(true)

    code = <<~'JIL'
      added = Tesla.addStop("Costco")::Boolean
    JIL
    Jil::Validator.validate!(code)
    jil = ::Jil::Executor.call(user, code, {})
    expect(jil.ctx[:error]).to be_nil
    expect(jil.ctx[:vars][:added][:value]).to be(true)
  end
end
