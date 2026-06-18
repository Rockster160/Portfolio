require "rails_helper"

RSpec.describe "Tesla Jil reproduction" do
  let(:user) { User.me }

  it "Tesla.start with TeslaStartOptions content block - what happens?" do
    code = <<~'JIL'
      started = Tesla.start({
        tso1 = TeslaStartOptions.navigate("Bedrock 1234 Some St")::Hash
      })::Boolean
    JIL

    fake = double("TeslaControl")
    expect(fake).to receive(:start_car)
    expect(fake).to receive(:navigate).with("Bedrock 1234 Some St")
    allow(::TeslaControl).to receive(:me).and_return(fake)

    result = ::Jil::Executor.call(user, code, {})
    puts "RESULT: #{result.inspect}"
  end

  it "validates the code" do
    code = <<~'JIL'
      started = Tesla.start({
        tso1 = TeslaStartOptions.navigate("Home")::Hash
      })::Boolean
    JIL
    Jil::Validator.validate!(code)
  end
end
