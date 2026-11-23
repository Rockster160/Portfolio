require "rails_helper"

RSpec.describe Jil::Methods::PushNotification do
  let(:user) { User.me }
  let(:code) {
    <<~JIL
      closeData = Hash.new({
        kAction = Keyval.new("action", "close")::Keyval
      })::Hash
      noteData = Hash.new({})::Hash
      sent = PushNotification.notify({
        nTitle = PushNotificationData.title("Garage is open")::PushNotificationData
        nButtons = PushNotificationData.buttons({
          bClose = PushNotificationButton.button("Close it", "garage", closeData, false)::PushNotificationButton
          bNote = PushNotificationButton.button("Why?", "garage_note", noteData, true)::PushNotificationButton
        })::PushNotificationData
      })::Any
    JIL
  }
  let(:device) {
    AppDevice.issue!(
      user,
      name:             "Phone",
      apns_token:       "abc",
      apns_environment: "development",
      features:         ["push", "actionable_notifications"],
    ).first
  }

  let(:deliveries) { [] }

  before {
    allow(Apns).to receive(:deliver) { |**args|
      deliveries << args
      Apns::Result.new(status: 200)
    }
  }

  it "validates" do
    expect { Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "puts a button on the phone for each one, each firing its own trigger when pressed", :aggregate_failures do
    device
    Jil::Executor.call(user, code)

    payload = deliveries.find { |args| args[:push_type] == :alert }[:payload]
    expect(payload[:aps]).to include(alert: { title: "Garage is open" }, category: "buddy.dynamic")
    expect(payload[:actions]).to eq([
      { id: "button_0", title: "Close it" },
      { id: "button_1", title: "Why?", input: true },
    ])
    pressed = payload[:button_actions].transform_keys(&:to_s)
    expect(pressed["button_0"]).to include(kind: :trigger, value: "garage")
    expect(pressed["button_0"][:data].to_h.stringify_keys).to eq("action" => "close")
    expect(pressed["button_1"]).to include(kind: :trigger, value: "garage_note")
  end

  it "keeps the buttons out of what a browser draws" do
    sent = []
    allow(WebPushNotifications).to receive(:send_to) { |_user, payload, **| sent << payload }

    Jil::Executor.call(user, code)

    expect(sent.first).to include(title: "Garage is open")
    expect(sent.first.keys).not_to include(:actions, :buttons, :button_actions)
  end
end
