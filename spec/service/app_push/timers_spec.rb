require "rails_helper"

RSpec.describe AppPush::Timers do
  let(:user) { User.me }
  let(:device) {
    AppDevice.issue!(
      user,
      name:                 "Phone",
      apns_token:           "abc",
      push_to_start_tokens: { "timer" => "start-token" },
      features:             ["live_activities"],
    ).first
  }
  let(:timer) { Buddy::Timers.create!(user: user, seconds: 300, label: "Pasta") }
  let(:sent) { [] }

  around { |example| Sidekiq::Testing.fake! { example.run } }

  before do
    device
    allow(AppTimerPushWorker).to receive(:perform_async)
    allow(Apns).to receive(:deliver) { |**args|
      sent << args
      Apns::Result.new(status: 200)
    }
  end

  it "starts a Live Activity once, however many times the timer is announced", :aggregate_failures do
    described_class.sync(timer, :created)
    described_class.sync(timer, :started)

    expect(sent.length).to eq(1)
    start = sent.first
    expect(start).to include(token: "start-token", push_type: :liveactivity, topic_suffix: "push-type.liveactivity")
    expect(start[:payload][:aps]).to include(
      event:             "start",
      "attributes-type": "TimerActivityAttributes",
      attributes:        hash_including(timer_id: timer.id, name: "Pasta"),
      "content-state":   hash_including(state: "running", ends_at: timer.end_at.to_f),
      "relevance-score": 10_000_000_000 - timer.end_at.to_f,
    )
  end

  it "updates the registered activity on pause and ends it when the timer goes", :aggregate_failures do
    AppLiveActivity.create!(app_device: device, activity_id: "A1", kind: :timer, ref_id: timer.id.to_s, push_token: "live-1")

    timer.pause!
    described_class.sync(timer, :paused)
    expect(sent.last).to include(token: "live-1")
    expect(sent.last[:payload][:aps]).to include(
      event:             "update",
      "content-state":   hash_including(state: "paused"),
      "relevance-score": 1,
    )

    Buddy::Timers.stop!(timer)
    described_class.sync(timer, :archived)
    expect(sent.last[:payload][:aps]).to include(event: "end")
    expect(AppLiveActivity.find_by(activity_id: "A1").ended_at).to be_present
  end

  it "leaves a device alone that turned Live Activities off for timers" do
    device.update!(preferences: { live_activities_for_timers: false })
    described_class.sync(timer, :created)

    expect(sent).to be_empty
  end
end
