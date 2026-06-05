require "rails_helper"

RSpec.describe Jil::Methods::Timer, type: :service do
  let(:user) { create(:user) }
  # Slim Jil double — only the contracts the module actually leans on.
  # `cast(value, :Hash)` is the one tricky path; we shallow-convert hashes
  # to symbol keys to mirror what the real executor produces.
  let(:jil_stub) do
    Class.new do
      attr_reader :user, :ctx
      def initialize(user) ; @user = user ; @ctx = nil ; end
      def cast(value, type=nil)
        case type
        when :Hash    then value.respond_to?(:to_h) ? value.to_h.deep_symbolize_keys : {}
        when :Boolean then [true, "true", 1, "1"].include?(value)
        when :Array   then Array(value)
        else value
        end
      end
    end.new(user)
  end
  subject(:methods) { described_class.new(jil_stub) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
  end

  describe "#find" do
    let!(:phase) { create(:timer, user: user, name: "Phase",  kind: :dial,
                                 duration_ms: nil, dial_config: { sections: [{ name: "Prep" }] }) }
    let!(:swarm) { create(:timer, user: user, name: "Swarm",  kind: :dial,
                                 duration_ms: nil, dial_config: { sections: [{ name: "A" }] }) }

    it "matches by case-insensitive name fragment" do
      expect(methods.find("phas")).to eq(phase)
    end

    it "matches by numeric id" do
      expect(methods.find(swarm.id)).to eq(swarm)
    end
  end

  describe "#list / #on_page" do
    let!(:page)    { create(:timer_page, user: user, name: "Slime Colony", slug: "slime-colony") }
    let!(:home_t)  { create(:timer, user: user, name: "Home", duration_ms: 60_000) }
    let!(:page_t)  { create(:timer, user: user, name: "On Page", duration_ms: 60_000, timer_page: page) }

    it "list returns all of the user's live timers" do
      expect(methods.list).to match_array([home_t, page_t])
    end

    it "on_page filters by page slug" do
      expect(methods.on_page("slime-colony")).to eq([page_t])
    end

    it "on_page(nil) returns Home page timers" do
      expect(methods.on_page(nil)).to eq([home_t])
    end
  end

  describe "#add" do
    it "creates a countdown with duration translated to duration_ms" do
      details = { name: "Tea", duration: 90, repeat: true }
      timer = methods.add(details)

      expect(timer).to be_a(Timer)
      expect(timer.duration_ms).to eq(90_000)
      expect(timer.repeat).to be(true)
      expect(timer.kind).to eq("countdown")
    end

    it "parses dial_text into structured sections with colors and weights" do
      details = {
        name:      "Phase",
        kind:      "dial",
        dial_text: "Setup *2 #f00\nCombat #00ff00: Attack #f0f, Defend",
      }
      timer = methods.add(details)
      sections = timer.reload.dial_config["sections"]

      expect(sections.length).to eq(2)
      expect(sections[0]).to include("name" => "Setup", "weight" => 2.0, "color" => "#f00")
      expect(sections[1]).to include("name" => "Combat", "color" => "#00ff00")
      expect(sections[1]["subs"]).to eq([{ "name" => "Attack", "color" => "#f0f" }, "Defend"])
    end
  end

  describe "#update" do
    let!(:dial) { create(:timer, user: user, name: "Phase", kind: :dial, duration_ms: nil,
                                 dial_config: { sections: [{ name: "Old" }] }) }

    it "replaces dial_config from dial_text" do
      methods.update("phase", { dial_text: "A\nB" })
      expect(dial.reload.dial_config["sections"].map { |s| s["name"] }).to eq(%w[A B])
    end

    it "applies start_offset onto dial_config without dropping sections" do
      methods.update("phase", { dial_text: "A\nB\nC", start_offset: -10 })
      cfg = dial.reload.dial_config
      expect(cfg["start_offset"]).to eq(-10.0)
      expect(cfg["sections"].length).to eq(3)
    end
  end

  describe "lifecycle methods" do
    let!(:dial) { create(:timer, user: user, name: "Phase", kind: :dial, duration_ms: nil,
                                 dial_config: { sections: [{ name: "Prep" }, { name: "Swarm" }, { name: "Settle" }] }) }

    it "advance bumps dial_step_index" do
      methods.advance("phase", 1)
      expect(dial.reload.dial_step_index).to eq(1)
    end

    it "goto jumps to the named section" do
      methods.goto("phase", "Settle")
      expect(dial.reload.dial_step_index).to eq(2)
    end

    it "reset returns the dial to step 0" do
      dial.update!(dial_step_index: 2)
      methods.reset("phase")
      expect(dial.reload.dial_step_index).to eq(0)
    end
  end

  describe "counter increment" do
    let!(:cnt) { create(:timer, user: user, name: "Score", kind: :counter, duration_ms: nil, value: 0) }

    it "increments a counter and accepts negative values" do
      methods.increment("score", 3)
      expect(cnt.reload.value).to eq(3)
      methods.increment("score", -1)
      expect(cnt.reload.value).to eq(2)
    end
  end
end
