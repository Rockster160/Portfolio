require "rails_helper"

# Which VALUES a trigger key actually takes — the half nothing recorded, and the
# reason two dead watches passed validation on the same day.
#
# `laundry:action:stop` names a real scope and a real key. `laundry` is fired by
# a button and a spoken command, both of which send a START; there has never
# been a stop. The appliances report on `hass-trigger`. Both the washer watch
# and the dryer watch were written against `laundry`, validated, and sat silent.
RSpec.describe Buddy::TriggerShapes do
  let(:user) { create(:user) }

  before { Rails.cache.clear }

  def observe(scope, payload)
    Rails.cache.delete("buddy:shape:#{user.id}:#{scope}")
    described_class.observe(user, scope, payload)
  end

  def values_for(scope)
    JilTriggerShape.find_by(user_id: user.id, scope: scope).observed_values
  end

  describe "learning them" do
    it "remembers the values a discriminator key fires with" do
      observe("hass-trigger", { "device_name" => "Washer", "type" => "stop" })
      observe("hass-trigger", { "device_name" => "Dryer", "type" => "start" })

      expect(values_for("hass-trigger")["device_name"]).to eq(%w[Dryer Washer])
      expect(values_for("hass-trigger")["type"]).to eq(%w[start stop])
    end

    it "keeps booleans, which read as strings in a listener" do
      observe("hass-sensor", { "detected" => true })

      expect(values_for("hass-sensor")["detected"]).to eq(["true"])
    end

    it "leaves ids and timestamps alone" do
      observe("event", { "id" => 44, "timestamp" => Time.current, "action" => "added" })

      expect(values_for("event").keys).to eq(["action"])
    end

    it "never stores prose, however short it happens to be" do
      observe("event", { "action" => "added", "note" => "ok", "body" => "hi" })

      expect(values_for("event").keys).to eq(["action"])
    end

    it "retires a key that turns out to be data rather than an enum" do
      (described_class::MAX_VALUES + 2).times { |i| observe("item", { "name" => "thing #{i}" }) }

      expect(values_for("item")["name"]).to eq(described_class::MANY)
    end

    it "keeps a retired key retired, so it can't start collecting again" do
      (described_class::MAX_VALUES + 2).times { |i| observe("item", { "name" => "thing #{i}" }) }
      observe("item", { "name" => "one more" })

      expect(values_for("item")["name"]).to eq(described_class::MANY)
    end

    it "reaches values nested inside the payload" do
      observe("item", { "list" => { "name" => "Claude" } })

      expect(values_for("item")["list.name"]).to eq(["Claude"])
    end
  end

  describe "reading them back" do
    it "reports a closed set, and nothing for a key it can't vouch for" do
      observe("laundry", { "action" => "start" })

      expect(described_class.known_values(user, "laundry", "action")).to eq(["start"])
      expect(described_class.known_values(user, "laundry", "nonsense")).to be_nil
      expect(described_class.known_values(user, "never-fired", "action")).to be_nil
    end

    it "has no opinion on a key that outgrew being an enum" do
      (described_class::MAX_VALUES + 2).times { |i| observe("item", { "name" => "thing #{i}" }) }

      expect(described_class.known_values(user, "item", "name")).to be_nil
    end

    it "shows the real values alongside the field, for whoever is writing one" do
      observe("hass-trigger", { "device_name" => "Washer", "type" => "stop" })
      observe("hass-trigger", { "device_name" => "Dryer", "type" => "start" })

      fields = described_class.for_user(user).detect { |r| r[:scope] == "hass-trigger" }[:fields]

      expect(fields).to include("type (string: start | stop)")
      expect(fields).to include("device_name (string: Dryer | Washer)")
    end
  end

  describe "refusing a listener that filters on a value that never occurs" do
    def gap(listener)
      Buddy::ListenerTargets.missing(listener, user: user)
    end

    before do
      observe("laundry", { "action" => "start" })
      observe("hass-trigger", { "device_name" => "Washer", "type" => "stop" })
      observe("hass-trigger", { "device_name" => "Dryer", "type" => "start" })
    end

    it "refuses the one that was written twice" do
      expect(gap("laundry:action:stop")).to include("start").and(include("stop"))
    end

    it "allows the value that does occur" do
      expect(gap("laundry:action:start")).to be_nil
    end

    it "allows the listener the appliances really need" do
      expect(gap("hass-trigger:device_name::Dryer type::stop")).to be_nil
      expect(gap("hass-trigger:device_name::Washer type::stop")).to be_nil
    end

    it "catches a wrong value in a trailing term, not just the first" do
      expect(gap("hass-trigger:device_name::Dryer type::finished")).to include("finished")
    end

    it "catches a device that has never reported" do
      expect(gap("hass-trigger:device_name::Toaster type::stop")).to include("Toaster")
    end

    it "says nothing about a key it has never recorded" do
      expect(gap("hass-trigger:whatever::anything")).to be_nil
    end

    it "leaves patterns alone — several things could satisfy one" do
      expect(gap("hass-trigger:device_name:/^Dry/")).to be_nil
      expect(gap("hass-trigger:type:ANY(start stop)")).to be_nil
    end

    it "does not refuse a substring of a real value, which single-colon matches" do
      expect(gap("hass-trigger:device_name:Dry")).to be_nil
    end
  end

  # The whole point is that a wrong guess fails while somebody is still there to
  # be told, rather than looking set for a month.
  describe "setting the dryer alarm" do
    let!(:hass_task) {
      Task.create!(
        user: user, name: "Hass Triggers", listener: "hass-trigger",
        code: "", enabled: true, buddy_enabled: true
      )
    }
    let!(:laundry_task) {
      Task.create!(
        user: user, name: "Do Laundry", listener: "laundry:start",
        code: "", enabled: true, buddy_enabled: true
      )
    }
    let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
    let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      observe("laundry", { "action" => "start" })
      observe("hass-trigger", { "device_name" => "Dryer", "type" => "stop" })
      Rails.cache.delete("jil:wired_scopes:#{user.id}")
    end

    def alarm(listener)
      markers = [{
        tool_name: :alarm,
        payload:   {
          label:       "Dryer's done",
          trigger:     "custom",
          listener:    listener,
          when_phrase: "when the dryer stops",
        },
        span:      [0, 0],
      }]
      Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
    end

    it "refuses the laundry guess instead of saving a watch that can't fire" do
      expect { alarm("laundry:action:stop") }.not_to change(BuddyWatch, :count)
    end

    it "takes the real one" do
      expect { alarm("hass-trigger:device_name::Dryer type::stop") }.to change(BuddyWatch, :count).by(1)
    end
  end
end
