require "rails_helper"

# Multi-stop trip path: Tesla.start({ TeslaStartOptions.waypoints(...) })
# should call TeslaControl#navigate_trip with the array, and NOT fall back
# into the single-destination navigate path.
RSpec.describe "Jil Tesla multi-stop trip" do
  let(:user) { User.me }
  let(:ctrl) { instance_double(::TeslaControl) }

  before { allow(::TeslaControl).to receive(:me).and_return(ctrl) }

  it "dispatches waypoints to TeslaControl#navigate_trip" do
    expect(ctrl).to receive(:start_car)
    expect(ctrl).to receive(:navigate_trip).with(
      [
        hash_including("name" => "Costco"),
        hash_including("name" => "Home"),
      ],
    )
    expect(ctrl).not_to receive(:navigate)

    code = <<~'JIL'
      stops = Array.new({
        a = Hash.new({
          a1 = Keyval.new("name", "Costco")::Keyval
          a2 = Keyval.new("lat", 40.5)::Keyval
          a3 = Keyval.new("lng", -111.9)::Keyval
        })::Hash
        b = Hash.new({
          b1 = Keyval.new("name", "Home")::Keyval
          b2 = Keyval.new("lat", 40.6)::Keyval
          b3 = Keyval.new("lng", -112.0)::Keyval
        })::Hash
      })::Array
      started = Tesla.start({
        wp = TeslaStartOptions.waypoints(stops)::Hash
      })::Boolean
    JIL
    Jil::Validator.validate!(code)
    jil = ::Jil::Executor.call(user, code, {})
    expect(jil.ctx[:error]).to be_nil
    expect(jil.ctx[:vars][:started][:value]).to be(true)
  end

  it "waypoints win when both navigate and waypoints are present" do
    expect(ctrl).to receive(:start_car)
    expect(ctrl).to receive(:navigate_trip).once
    expect(ctrl).not_to receive(:navigate)

    code = <<~'JIL'
      stops = Array.new({
        a = Hash.new({
          a1 = Keyval.new("lat", 40.5)::Keyval
          a2 = Keyval.new("lng", -111.9)::Keyval
        })::Hash
      })::Array
      started = Tesla.start({
        nav = TeslaStartOptions.navigate("Home")::Hash
        wp = TeslaStartOptions.waypoints(stops)::Hash
      })::Boolean
    JIL
    Jil::Validator.validate!(code)
    ::Jil::Executor.call(user, code, {})
  end
end
