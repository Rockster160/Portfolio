require "rails_helper"

RSpec.describe Jil::ListenerMatch do
  # The `item` payload as ListItem#jil_serialize builds it.
  let(:payload) {
    {
      id:      9001,
      name:    "Look at the audit",
      action:  "added",
      list:    { id: 379, name: "Claude", description: nil },
      section: { id: 127, name: "Broker" },
    }
  }

  describe "a key path written with dots" do
    it "names the colon form it should have been" do
      fault = described_class.fault("item:action:added list.name::Claude")

      expect(fault).to include("list.name")
      expect(fault).to include("list:name")
    end

    it "catches one nested behind the scope too" do
      expect(described_class.fault("item:list.name::Claude")).to be_present
    end

    it "passes a listener whose keys are separated properly" do
      expect(described_class.fault("item:action:added list:name::Claude section:name::Broker")).to be_nil
    end

    it "leaves a dot inside a VALUE alone" do
      [
        "email:from:rocco11nicholls@gmail.com",
        'email:from:"no.reply.alerts@chase.com"',
        "email:from:/Chase@e\\.chase\\.com/",
        "transactions:amount::12.50",
      ].each { |listener| expect(described_class.fault(listener)).to be_nil }
    end

    it "leaves a bare term alone, which is a value and not a key" do
      expect(described_class.fault("item:action:added no.reply@chase.com")).to be_nil
    end

    it "leaves the real listeners already running alone" do
      [
        "item:action::added",
        'item:list:name::"Before Bed"',
        "event:add name::Game",
        "event:ANY(add changed) name:ANY(food soda drink)",
        "travel:action::OR(arrived departed)",
        "email:from:venmo subject:/Chelsea Haven paid you/",
        "tesla_shift:shift:N",
        "hass-sensor:location::Doorbell",
      ].each { |listener| expect(described_class.fault(listener)).to be_nil }
    end
  end

  describe "a watch will not save with one" do
    let(:user) { create(:user) }
    let(:conversation) { ByteConversation.create!(user: user) }

    def watch_with(listener)
      BuddyWatch.new(
        user:              user,
        byte_conversation: conversation,
        body:              "something landed",
        trigger_scope:     "item",
        listener:          listener,
      )
    end

    it "refuses it, saying which colon form was meant" do
      watch = watch_with("item:action:added list.name::Claude")

      expect(watch).not_to be_valid
      expect(watch.errors[:listener].join).to include("list:name")
    end

    it "saves the same watch once the dots are colons" do
      expect(watch_with("item:action:added list:name::Claude")).to be_valid
    end
  end

  describe "what the dots would have cost" do
    it "matches nothing as written, and everything once the dots are colons" do
      expect(described_class.call("item:action:added list.name::Claude section.name::Broker", :item, payload)).to be(false)
      expect(described_class.call("item:action:added list:name::Claude section:name::Broker", :item, payload)).to be(true)
    end

    it "does not need the scope repeated on every term" do
      expect(described_class.call("item:action:added name::Claude", :item, payload)).to be(true)
      expect(described_class.call("item:action:added item:list:id::379", :item, payload)).to be(true)
    end
  end
end
