require "rails_helper"

RSpec.describe AppPush do
  let(:user) { User.me }
  let(:device) {
    AppDevice.issue!(user, name: "Phone", apns_token: "abc", features: ["push", "actionable_notifications"]).first
  }
  let(:sent) { [] }

  before do
    device
    allow(Apns).to receive(:deliver) { |**args|
      sent << args
      Apns::Result.new(status: 200)
    }
  end

  it "turns a web push payload into an alert with the badge, tag and link" do
    described_class.deliver(
      user, {
        title: "Byte",
        body:  "Dinner's ready",
        tag:   "byte-9",
        data:  { url: "/byte", count: 3, conversation_id: 4 },
      }, channel: :byte
    )

    expect(sent.sole[:payload]).to include(
      aps:             hash_including(alert: { title: "Byte", body: "Dinner's ready" }, badge: 3, "thread-id": "byte"),
      tag:             "byte-9",
      url:             "/byte",
      conversation_id: 4,
    )
  end

  it "rings a fired timer with the sound it makes on the page", :aggregate_failures do
    sound = { when: { type: :complete }, then: { type: :sound, chime: :bell, cadence: "10s" } }
    chimed = create(:timer, user: user, callbacks: [sound])
    buddy = create(:timer, user: user, timer_page: Buddy::Timers.page_for(user))
    plain = create(:timer, user: user)

    expect([chimed, buddy, plain].map(&:alert_sound)).to eq([:timer_bell_10s, :buddy_alarm, nil])

    described_class.deliver(user, { title: "Tea", sound: chimed.alert_sound }, channel: :timers)
    described_class.deliver(user, { title: "Hi" }, channel: :byte)
    expect(sent.map { |args| args.dig(:payload, :aps, :sound) }).to eq(["timer_bell_10s.caf", "default"])
  end

  it "sends a count with nothing to show as a badge, and empties the tray at zero", :aggregate_failures do
    described_class.deliver(user, { data: { count: 0 } }, channel: :byte)

    expect(sent.pluck(:push_type)).to eq([:alert, :background])
    expect(sent.first[:payload]).to eq(aps: { badge: 0 })
    expect(sent.last[:payload]).to include(clear_all: true)
  end

  it "takes a dismissed tag off the phone" do
    described_class.deliver(user, { dismiss: true, tag: "agenda-4" }, channel: :agenda)

    expect(sent.sole).to include(push_type: :background, payload: hash_including(remove_tags: ["agenda-4"]))
  end

  it "skips a channel the device didn't ask for" do
    device.update!(preferences: { push_channels: ["byte"] })
    described_class.deliver(user, { title: "Chore" }, channel: :chores)

    expect(sent).to be_empty
  end

  it "leaves the badge off when the device turned badges off" do
    device.update!(preferences: { push_badges: false })
    described_class.deliver(user, { title: "Hi", data: { count: 2 } }, channel: :byte)

    expect(sent.sole[:payload][:aps]).not_to have_key(:badge)
  end

  it "carries buttons only to a device that answers from notifications", :aggregate_failures do
    payload = {
      title: "Garage open",
      data:  { actions: [{ id: "action-1", title: "Close", value: "1" }], answer: { kind: :action, request_id: "r1" } },
    }
    described_class.deliver(user, payload, channel: :byte)
    expect(sent.last[:payload]).to include(actions: [hash_including(title: "Close")], answer: { kind: :action, request_id: "r1" })
    expect(sent.last[:payload][:aps][:category]).to eq("buddy.dynamic")

    device.update!(features: ["push"])
    described_class.deliver(user, payload, channel: :byte)
    expect(sent.last[:payload]).not_to have_key(:actions)
  end

  it "forgets a token Apple says is gone" do
    allow(Apns).to receive(:deliver).and_return(Apns::Result.new(status: 410, reason: :Unregistered))
    described_class.deliver(user, { title: "Hi" }, channel: :byte)

    expect(device.reload.apns_token).to be_nil
  end

  it "keeps web push from reaching the web app once the device stands in for it" do
    device.update!(preferences: { native_push_replaces_web_push: true })
    sub = user.push_subs.create!(channel: :byte, endpoint: "https://web.push.apple.com/x", p256dh: "p", auth: "a", registered_at: Time.current)
    allow(Rails.env).to receive(:development?).and_return(false)
    allow(WebPushNotifications).to receive(:deliver_push)

    result = WebPushNotifications.send_to(user, { title: "Hi" }, channel: :byte)

    expect(result).to eq("Push success")
    expect(WebPushNotifications).not_to have_received(:deliver_push).with(anything, sub, anything, anything)
    expect(sent.length).to eq(1)
  end

  describe AppDevices::NotificationActions do
    it "offers a single-choice prompt's choices as buttons" do
      prompt = user.prompts.create!(question: "Mood?", options: [{ type: "choices", question: "Mood", choices: ["Good", "Meh"] }])

      expect(described_class.for_prompt(prompt)).to include(
        actions: [hash_including(title: "Good", value: "Good"), hash_including(title: "Meh")],
        answer:  { kind: :prompt, prompt_id: prompt.id, question: "Mood" },
      )
    end

    it "gives a text question a reply field and leaves a multi-question prompt to the app", :aggregate_failures do
      text = user.prompts.create!(question: "Note?", options: [{ type: "text", question: "Note" }])
      many = user.prompts.create!(question: "Two", options: [{ type: "text", question: "A" }, { type: "text", question: "B" }])

      expect(described_class.for_prompt(text)[:actions]).to eq([{ id: "reply", title: "Reply", input: true, placeholder: "Note" }])
      expect(described_class.for_prompt(many)).to eq({})
    end
  end
end
