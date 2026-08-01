require "rails_helper"

# Prod 1479-1482: "Can you let me know the next time somebody is seen by the
# doorbell/front yard camera?" got "Not with what's wired here, no" - and then,
# after being told it IS set up through the house sensors, the same no again.
#
# Both were wrong. Twenty-eight tasks were listening on `hass-sensor` and
# `hass-button` at the time, three of them doorbells. Home Assistant posts to
# /jil/webhook, which takes the scope off the request, so none of those scopes
# appears as a literal anywhere in app code - and KNOWN_SCOPES is greped from
# app code, so it refused every one of them.
#
# A task already listening on a scope is the evidence that it fires. Nobody
# wires a task to a trigger that never arrives.
RSpec.describe "Buddy watching the house" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:tool)   { Buddy::Tools[:remind_when] }

  # The real ones off prod, since the point is that these are what makes the
  # scope legible at all.
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

  # Straight off task 274's code: `detected`, `location`, `subject`.
  def detection(location:, subject: "person", detected: true)
    { "detected" => detected, "location" => location, "subject" => subject, "device_name" => "#{location} Cam" }
  end

  before { Rails.cache.clear }

  describe "accepting a scope only an integration fires" do
    it "sets the watch the two prod replies said was impossible" do
      result = set!("hass-sensor:location:/^Doorbell$/ subject:person detected:true")

      expect(result[:watch_id]).to be_present
      expect(BuddyWatch.last.trigger_scope).to eq("hass-sensor")
    end

    it "fires when a person is seen at the doorbell" do
      set!("hass-sensor:location:/^Doorbell$/ subject:person detected:true")

      expect(BuddyWatch.last.matches?(detection(location: "Doorbell"))).to be(true)
    end

    it "ignores the cat, and the driveway" do
      set!("hass-sensor:location:/^Doorbell$/ subject:person detected:true")
      watch = BuddyWatch.last

      expect(watch.matches?(detection(location: "Doorbell", subject: "pet"))).to be(false)
      expect(watch.matches?(detection(location: "Driveway"))).to be(false)
    end

    it "ignores a detection clearing" do
      set!("hass-sensor:location:/^Doorbell$/ subject:person detected:true")

      expect(BuddyWatch.last.matches?(detection(location: "Doorbell", detected: false))).to be(false)
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
      expect { set!("hass-doorbel:rang:true") }
        .to raise_error(/nothing here has ever fired a "hass-doorbel" trigger/)
    end

    it "rejects one the person has no task for, even if someone else does" do
      Task.create!(
        user:     create(:user),
        name:     "Their sensor",
        listener: "hass-whatever",
        code:     "// noop",
        enabled:  true,
      )

      expect { set!("hass-whatever:x:1") }.to raise_error(/never fire/)
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

      expect { set!("hass-retired:x:1") }.to raise_error(/never fire/)
    end
  end

  describe "the trigger actually reaching the watch" do
    it "fires the watch off a webhook-shaped trigger" do
      set!("hass-sensor:location:/^Doorbell$/ subject:person detected:true")
      watch = BuddyWatch.last

      expect(Buddy::CompanionDelivery).to receive(:deliver_prompt).once
      ::Jil.trigger(user, :"hass-sensor", detection(location: "Doorbell"))

      expect(watch.reload.fired_at).to be_present
    end

    it "leaves it alone when the detection isn't the one asked for" do
      set!("hass-sensor:location:/^Doorbell$/ subject:person detected:true")

      expect(Buddy::CompanionDelivery).not_to receive(:deliver_prompt)
      ::Jil.trigger(user, :"hass-sensor", detection(location: "Backyard"))
    end
  end

  describe "finding it in the first place" do
    let(:guide) { Buddy::GPT::ListenerTool.new(user, convo) }

    def search(about)
      JSON.parse(guide.call("about" => about, "scope" => nil))
    end

    # The word they used is "doorbell". Nothing anywhere exposes the string
    # "hass-sensor" to them or to the model, so the search has to bridge it.
    it "finds the doorbell from the word they said" do
      matches = search("doorbell").fetch("matches")

      expect(matches.pluck("listener")).to include("hass-sensor:location:doorbell type:rang rang:true")
    end

    it "finds the camera from 'front yard camera'" do
      expect(search("front yard camera").fetch("matches").pluck("listener")).to include("hass-sensor:location")
    end

    it "comes back empty for something genuinely not wired" do
      expect(search("aquarium").fetch("matches")).to be_empty
    end

    it "doesn't match on filler words alone" do
      expect(search("the a my").fetch("matches")).to be_empty
    end

    # Scope names are unguessable from outside, so the index is how the model
    # learns `hass-sensor` is a thing at all.
    it "lists the scopes something is really listening on" do
      expect(search("doorbell").fetch("scopes")).to include("hass-sensor" => 2)
    end

    it "tells the model that a non-empty match means yes" do
      expect(search("doorbell").fetch("next")).to match(/IS watchable/)
    end
  end
end
