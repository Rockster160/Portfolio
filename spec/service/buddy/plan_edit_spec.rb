require "rails_helper"

# One request, several rows - a watch, a reminder, the rule that stops it -
# seen, changed and cancelled as one thing.
RSpec.describe "Buddy plans" do
  let(:user) { create(:user) }
  let!(:sensor) {
    Task.create!(
      user: user, name: "Garage Log", listener: "hass-sensor:device_name::garage_door",
      code: "", enabled: true, buddy_enabled: true
    )
  }
  let!(:quiet) {
    Task.create!(
      user: user, name: "Whisper Quiet", listener: "whisper-quiet", description: "Drops the volume",
      code: "", enabled: true, buddy_enabled: true
    )
  }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:ctx)    { Buddy::ToolContext.new(user, conversation: convo) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(::Jil).to receive(:trigger).and_return(true)
    Rails.cache.delete("jil:wired_scopes:#{user.id}")
  end

  def message
    convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok")
  end

  def garage_watch(**extra)
    {
      tool_name: :remind_when,
      payload:   {
        text:        "🚪 The garage just opened.",
        trigger:     "custom",
        listener:    "hass-sensor:device_name::garage_door",
        when_phrase: "when the garage opens",
        repeat:      true,
        **extra,
      },
    }
  end

  def midnight_check(at: 4.hours.from_now)
    { tool_name: :schedule_reminder, payload: { text: "Is the garage shut?", at: at.iso8601 } }
  end

  def set_up!(*markers)
    Buddy::ProposalBuilder.create(user: user, byte_message: message, markers: markers)
  end

  def edit(**args)
    tool = Buddy::Tools[:edit_plan]
    payload, errors = Buddy::Tools.validate_payload(tool, args)
    raise errors.join("; ") if errors.any?

    resolved = payload.merge(tool[:confirm].call(payload, ctx)[:resolved])
    tool[:execute].call(resolved, ctx)
  end

  describe "making one" do
    it "puts every row from one reply in the same plan" do
      set_up!(garage_watch, midnight_check)

      ids = [BuddyWatch.last.plan_id, BuddyReminder.last.plan_id]
      expect(ids.uniq.length).to eq(1)
      expect(ids.first).to be_present
    end

    it "keeps two replies' rows apart" do
      set_up!(garage_watch)
      set_up!(midnight_check)

      expect(BuddyWatch.last.plan_id).not_to eq(BuddyReminder.last.plan_id)
    end

    it "tags both rows with the plan in context" do
      set_up!(garage_watch, midnight_check)
      context = Buddy::Context.build(user, convo)

      expect(context[:upcoming_reminders].first[:plan]).to eq(BuddyWatch.last.plan_id)
      expect(context[:active_watches].first[:plan]).to eq(BuddyWatch.last.plan_id)
    end
  end

  describe "changing one" do
    before { set_up!(garage_watch, midnight_check) }

    let(:plan_id) { BuddyWatch.last.plan_id }

    it "moves every timed part by a shift" do
      was = BuddyReminder.last.fire_at

      edit(plan: plan_id, shift: "+1h")

      expect(BuddyReminder.last.fire_at).to be_within(1.second).of(was + 1.hour)
    end

    it "aims at one part by its own id" do
      edit(plan: BuddyWatch.last.id.to_s, only_if: [{ days: "weekdays" }].to_json)

      expect(BuddyWatch.last.condition).to be_present
      expect(BuddyReminder.last.condition).to be_nil
    end

    it "finds it by words from any part" do
      edit(plan: "garage shut", shift: "+1h")

      expect(BuddyReminder.last.fire_at).to be > 4.hours.from_now
    end

    it "puts one condition on every part that acts" do
      edit(plan: plan_id, only_if: [{ after: "22:00", before: "06:00" }].to_json)

      expect(BuddyWatch.last.condition).to include("kind" => "time", "after" => "22:00")
      expect(BuddyReminder.last.condition).to include("kind" => "time")
    end

    it "clears the conditions with an empty list" do
      edit(plan: plan_id, only_if: [{ after: "22:00" }].to_json)
      edit(plan: plan_id, only_if: "[]")

      expect(BuddyWatch.last.condition).to be_nil
    end

    it "changes what the watch waits for" do
      Task.create!(user: user, name: "Door Log", listener: "hass-sensor:device_name::front_door", code: "", enabled: true, buddy_enabled: true)
      Rails.cache.delete("jil:wired_scopes:#{user.id}")

      edit(plan: plan_id, trigger: "custom", listener: "hass-sensor:device_name::front_door", when_phrase: "when the front door opens")

      expect(BuddyWatch.last.listener).to eq("hass-sensor:device_name::front_door")
      expect(BuddyWatch.last.metadata["human_when"]).to include("front door")
    end

    it "makes the watch run steps instead of speaking" do
      edit(plan: BuddyWatch.last.id.to_s, steps: [{ tool_name: "run_jil_task", payload: { name: "Whisper Quiet" } }].to_json)

      expect(BuddyWatch.last.kind).to eq("action")
      expect(BuddyWatch.last.run_steps.first.dig("payload", "name")).to eq("Whisper Quiet")
    end

    # Two parts speak, so "change the wording" doesn't say which.
    it "asks which part when wording could mean either" do
      expect { edit(plan: plan_id, text: "Garage!") }.to raise_error(/2 parts of this plan says something.*pass one's id/)
    end

    it "refuses a shift into the past before anything moves" do
      expect { edit(plan: plan_id, shift: "-5h") }.to raise_error(/in the past/)
    end

    it "puts every part back when undone" do
      was = BuddyReminder.last.fire_at
      result = edit(plan: plan_id, shift: "+1h", only_if: [{ after: "22:00" }].to_json)

      result[:reverts].each { |rv| Buddy::Reverter.call(JSON.parse(rv.to_json)) }

      expect(BuddyReminder.last.fire_at).to be_within(1.second).of(was)
      expect(BuddyWatch.last.condition).to be_nil
    end

    it "removes the whole thing" do
      edit(plan: plan_id, cancel: true)

      expect(BuddyWatch.where(user: user)).to be_empty
      expect(BuddyReminder.where(user: user)).to be_empty
    end
  end

  describe "a watch gated on the rest of the rule" do
    before { allow(Buddy::CompanionDelivery).to receive(:deliver_prompt) }

    def night_watch!
      set_up!(garage_watch(repeat: false, only_if: [{ after: "22:00", before: "06:00" }].to_json))
      BuddyWatch.last
    end

    def at(clock, &block)
      travel_to(Time.find_zone("America/Denver").parse("2026-10-23 #{clock}"), &block)
    end

    it "fires inside the window" do
      watch = night_watch!
      at("23:00") { Buddy::WatchMatcher.fire!(watch) }

      expect(watch.reload.fired_at).to be_present
    end

    # The garage opened, but not after ten - only half of what it waits for.
    it "stays armed outside it, one-shot or not" do
      watch = night_watch!
      at("15:00") { Buddy::WatchMatcher.fire!(watch) }

      expect(watch.reload.fired_at).to be_nil
      expect(watch.last_fired_at).to be_nil
    end

    it "leaves a chip saying why, once an hour at most" do
      watch = night_watch!
      chips = -> { convo.byte_messages.where("metadata->>'tool_name' = 'schedule_condition'").count }

      at("15:00") { Buddy::WatchMatcher.fire!(watch) }
      at("15:10") { Buddy::WatchMatcher.fire!(watch.reload) }
      expect(chips.call).to eq(1)

      at("16:30") { Buddy::WatchMatcher.fire!(watch.reload) }
      expect(chips.call).to eq(2)
    end

    it "says what it waits on in the receipt" do
      night_watch!

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to include("only if it's after 10pm and before 6am")
    end
  end
end
