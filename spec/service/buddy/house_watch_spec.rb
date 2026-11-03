require "rails_helper"

# Home Assistant posts to /jil/webhook, which takes the scope off the request,
# so scopes like `hass-sensor` never appear as a literal in app code. A task
# already listening on a scope is the evidence that it fires.
RSpec.describe "Buddy watching the house" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:tool)   { Buddy::Tools[:remind_when] }

  let!(:doorbell) {
    task!(
      "hass-sensor:location:doorbell type:rang rang:true",
      name:        "Doorbell Rung",
      description: "Sends a push notification when the doorbell sensor reports a ring",
    )
  }
  let!(:cameras) {
    task!(
      "hass-sensor:location",
      name:        "Hass Cameras",
      description: "Records camera detections (pet, person, vehicle, motion) per location",
    )
  }

  def task!(listener, name:, description: nil)
    Task.create!(
      user: user, name: name, listener: listener, description: description,
      code: "// noop", enabled: true
    )
  end

  def ctx
    Buddy::ToolContext.new(user, conversation: convo)
  end

  def set!(listener, phrase: "when someone is seen at the front door")
    args    = { text: "someone's out front", trigger: "custom", listener: listener, when_phrase: phrase }
    confirm = tool[:confirm].call(args, ctx)
    tool[:execute].call(args.merge(confirm[:resolved]), ctx)
  end

  def detection(location:, subject: "person", detected: true)
    { "detected" => detected, "location" => location, "subject" => subject, "device_name" => "#{location} Cam" }
  end

  before { Rails.cache.clear }

  describe "accepting a scope only an integration fires" do
    it "sets a watch on it that fires for a person at the doorbell and nothing else", :aggregate_failures do
      result = set!("hass-sensor:location:/^Doorbell$/ subject:person detected:true")
      watch = BuddyWatch.last

      expect(result[:watch_id]).to eq(watch.id)
      expect(watch.trigger_scope).to eq("hass-sensor")
      expect(watch.matches?(detection(location: "Doorbell"))).to be(true)
      expect(watch.matches?(detection(location: "Doorbell", subject: "pet"))).to be(false)
      expect(watch.matches?(detection(location: "Driveway"))).to be(false)
      expect(watch.matches?(detection(location: "Doorbell", detected: false))).to be(false)
    end

    it "takes the doorbell ring listener verbatim off their own task" do
      set!("hass-sensor:location:doorbell type:rang rang:true", phrase: "when the doorbell rings")
      ring = { "location" => "doorbell", "type" => "rang", "rang" => true }

      expect(BuddyWatch.last.matches?(ring)).to be(true)
    end
  end

  # The relaxation is bounded by real listeners, not by giving up on the check -
  # a scope nothing has ever listened to is still a watch that sits there
  # forever, and they'd never find out.
  describe "still refusing what could never fire" do
    it "rejects an invented scope" do
      expect { set!("hass-doorbel:rang:true") }.to raise_error(/"hass-doorbel"/)
    end

    it "rejects one the person has no task for, even if someone else does" do
      Task.create!(
        user:     create(:user),
        name:     "Their sensor",
        listener: "hass-whatever",
        code:     "// noop",
        enabled:  true,
      )

      expect { set!("hass-whatever:x:1") }.to raise_error(/fire/)
    end

    it "refuses to store one past the tool either" do
      watch = BuddyWatch.new(
        user: user, byte_conversation: convo, body: "x",
        trigger_scope: "hass-nope", listener: "hass-nope:x", match: {}
      )

      expect(watch).not_to be_valid
    end

    # An archived or disabled task is not evidence the scope still fires.
    it "doesn't count a task that isn't running" do
      task!("hass-retired", name: "Old").update!(enabled: false)

      expect { set!("hass-retired:x:1") }.to raise_error(/fire/)
    end
  end

  describe "the trigger actually reaching the watch" do
    it "fires the watch off a webhook-shaped trigger, and only for the detection asked for" do
      set!("hass-sensor:location:/^Doorbell$/ subject:person detected:true")
      watch = BuddyWatch.last
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)

      ::Jil.trigger(user, :"hass-sensor", detection(location: "Backyard"))
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)

      ::Jil.trigger(user, :"hass-sensor", detection(location: "Doorbell"))
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).once
      expect(watch.reload.fired_at).to be_present
    end
  end

  describe "finding it in the first place" do
    let(:guide) { Buddy::GPT::ListenerTool.new(user, convo) }

    def search(about)
      JSON.parse(guide.call("about" => about, "scope" => nil))
    end

    # The word they used is "doorbell". Nothing anywhere exposes the string
    # "hass-sensor" to them or to the model, so the search has to bridge it.
    it "bridges the word they said to the scope something listens on", :aggregate_failures do
      doorbell = search("doorbell")
      expect(doorbell.fetch("matches").pluck("listener")).to include("hass-sensor:location:doorbell type:rang rang:true")
      # Scope names are unguessable from outside, so the index is how the model
      # learns `hass-sensor` is a thing at all.
      expect(doorbell.fetch("scopes")).to include("hass-sensor" => 2)

      expect(search("front yard camera").fetch("matches").pluck("listener")).to include("hass-sensor:location")
    end

    it "comes back empty for something not wired, or filler words alone", :aggregate_failures do
      expect(search("aquarium").fetch("matches")).to be_empty
      expect(search("the a my").fetch("matches")).to be_empty
    end
  end
end
