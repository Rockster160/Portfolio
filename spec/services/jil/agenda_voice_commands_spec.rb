require "rails_helper"

# Behavioral contract for the three Jil tasks deployed by
# `lib/scripts/agenda_voice_commands.rb`:
#   • Jarvis: Agenda Add  (tell:/^agenda add (?<rest>.+)$/)
#   • Jarvis: Let's Go    (tell:/^let'?s go$/)
#   • Jarvis: Add Stop    (tell:/^add (?:a )?stop:?\s+(?<dest>.+)$/)
#
# Jil source is embedded inline so this spec stays valid regardless of
# whether the script gets renamed/relocated post-prodExec. Update both
# in lockstep when the deployed Jil changes.
RSpec.describe "agenda voice commands" do
  let(:user) { User.me }

  AGENDA_ADD_CODE = <<~'JIL'.freeze
    data = Global.input_data()::Hash
    captures = data.get("named_captures")::Hash
    rest = captures.get("rest")::String
    hasTime = data.get("has_time")::Boolean
    startTs = data.get("timestamp")::Date

    durMin = Date.extract_minutes(rest)::Numeric
    hasDur = Boolean.compare(durMin, ">", 0)::Boolean
    noDur = Date.strip_duration(rest)::String

    splitParts = noDur.split(" at ")::Array
    splitCount = splitParts.length()::Numeric
    hasSplit = Boolean.compare(splitCount, ">", 1)::Boolean

    parsed = Global.if({
      hasSplitRef = Global.ref(hasSplit)::Boolean
    }, {
      beforeAt = splitParts.first()::String
      afterAt = splitParts.get(1)::String
      splitHash = Hash.new({
        kvName1 = Keyval.new("name", beforeAt)::Keyval
        kvLoc1 = Keyval.new("location", afterAt)::Keyval
      })::Hash
    }, {
      trimmed = noDur.replace("/^at\\s+/", "")::String
      plainHash = Hash.new({
        kvName2 = Keyval.new("name", trimmed)::Keyval
        kvLoc2 = Keyval.new("location", trimmed)::Keyval
      })::Hash
    })::Hash

    itemName = parsed.get("name")::String
    itemLoc = parsed.get("location")::String

    created = Global.if({
      hasDurRef = Global.ref(hasDur)::Boolean
    }, {
      startUsed = Global.if({
        hasTimeRef = Global.ref(hasTime)::Boolean
      }, {
        pickStartA = Global.ref(startTs)::Date
      }, {
        pickStartB = Date.now()::Date
      })::Date
      endUsed = startUsed.add(durMin, "minutes")::Date
      evtMade = Agenda.add_event("Rockster160", itemName, startUsed, endUsed)::AgendaItem
    }, {
      taskMade = Agenda.add_task("Rockster160", itemName, startTs)::AgendaItem
    })::AgendaItem

    locLen = itemLoc.length()::Numeric
    hasLoc = Boolean.compare(locLen, ">", 0)::Boolean

    updated = Global.if({
      hasLocRef = Global.ref(hasLoc)::Boolean
    }, {
      setLoc = created.update!({
        locSet = AgendaItemData.location(itemLoc)::Hash
      })::AgendaItem
    }, {
      noUpdate = Boolean.new(true)::Boolean
    })::Any

    effectiveStart = created.start_at()::Date
    whenStr = effectiveStart.format("%a, %b %-d at %-l:%M %p")::String
    msg = Text.new("Added: \"#{itemName}\" — #{whenStr}")::String
    stop = Global.stop_propagation()::Any
    out = Global.return(msg)::Any
  JIL

  LETS_GO_CODE = <<~'JIL'.freeze
    data = Global.input_data()::Hash
    items = Agenda.search("is:today is:upcoming", 50, "ASC")::Array
    located = items.select({
      cand = Keyword.Object()::AgendaItem
      candLoc = cand.location()::String
      candLocLen = candLoc.length()::Numeric
      candHasLoc = Boolean.compare(candLocLen, ">", 0)::Boolean
    })::Array
    locatedCount = located.length()::Numeric
    hasItem = Boolean.compare(locatedCount, ">", 0)::Boolean

    msg = Global.if({
      hasItemRef = Global.ref(hasItem)::Boolean
    }, {
      pick = located.first()::AgendaItem
      pickName = pick.name()::String
      pickLoc = pick.location()::String
      navResult = Tesla.navigate("#{pickLoc}")::Boolean
      okMsg = Text.new("On my way to #{pickName} (#{pickLoc})")::String
    }, {
      errMsg = Text.new("Nothing on the agenda")::String
    })::String
    stop = Global.stop_propagation()::Any
    out = Global.return(msg)::Any
  JIL

  ADD_STOP_CODE = <<~'JIL'.freeze
    data = Global.input_data()::Hash
    captures = data.get("named_captures")::Hash
    dest = captures.get("dest")::String
    added = Tesla.addStop(dest)::Boolean
    msg = Global.if({
      addedRef = Global.ref(added)::Boolean
    }, {
      okMsg = Text.new("Stop added: #{dest}")::String
    }, {
      errMsg = Text.new("Couldn't add stop: #{dest}")::String
    })::String
    stop = Global.stop_propagation()::Any
    out = Global.return(msg)::Any
  JIL

  around { |ex| Time.use_zone("Mountain Time (US & Canada)") { ex.run } }

  let!(:agenda) { Agenda.find_by(user: user, name: "Rockster160") || Agenda.create!(user: user, name: "Rockster160") }

  # Mirrors what Jarvis#command builds in trigger data: pre-stripped `words`,
  # parsed `timestamp`/`has_time`, and the listener's named_captures.
  def agenda_add_data(rest:, has_time: false, timestamp: nil)
    ts = timestamp || Time.current
    {
      words:           "agenda add #{rest}",
      full:            "agenda add #{rest}",
      has_time:        has_time,
      timestamp:       ts.is_a?(String) ? ts : ts.iso8601,
      named_captures: { rest: rest },
    }
  end

  it "validates all three Jil tasks" do
    expect { Jil::Validator.validate!(AGENDA_ADD_CODE) }.not_to raise_error
    expect { Jil::Validator.validate!(LETS_GO_CODE) }.not_to raise_error
    expect { Jil::Validator.validate!(ADD_STOP_CODE) }.not_to raise_error
  end

  describe "Jarvis: Agenda Add" do
    it "duration + 'at' location → EVENT with location, name from after 'at'" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        ts = Time.zone.local(2026, 6, 18, 16, 0)
        data = agenda_add_data(rest: "20 minutes at Costco", has_time: true, timestamp: ts)
        expect { Jil::Executor.call(user, AGENDA_ADD_CODE, data) }
          .to change { agenda.reload.agenda_items.count }.by(1)

        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.kind).to eq("event")
        expect(item.name).to eq("Costco")
        expect(item.location).to eq("Costco")
        expect(item.start_at).to eq(ts)
        expect(item.end_at).to eq(ts + 20.minutes)
      end
    end

    it "reversed phrasing 'Costco for 20m' → EVENT with name+location both 'Costco'" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        ts = Time.zone.local(2026, 6, 18, 16, 0)
        data = agenda_add_data(rest: "Costco for 20m", has_time: true, timestamp: ts)
        Jil::Executor.call(user, AGENDA_ADD_CODE, data)
        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.kind).to eq("event")
        expect(item.name).to eq("Costco")
        expect(item.location).to eq("Costco")
        expect(item.end_at).to eq(ts + 20.minutes)
      end
    end

    it "compact '1h 30m' → 90-minute event" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        ts = Time.zone.local(2026, 6, 18, 16, 0)
        data = agenda_add_data(rest: "Costco for 1h 30m", has_time: true, timestamp: ts)
        Jil::Executor.call(user, AGENDA_ADD_CODE, data)
        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.end_at).to eq(ts + 90.minutes)
      end
    end

    it "explicit 'meeting at Costco for 1h' → name=meeting, location=Costco" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        ts = Time.zone.local(2026, 6, 18, 16, 0)
        data = agenda_add_data(rest: "meeting at Costco for 1h", has_time: true, timestamp: ts)
        Jil::Executor.call(user, AGENDA_ADD_CODE, data)
        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.name).to eq("meeting")
        expect(item.location).to eq("Costco")
        expect(item.end_at).to eq(ts + 1.hour)
      end
    end

    it "no time, just duration → EVENT starting now" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        data = agenda_add_data(rest: "Costco for 20 minutes", has_time: false, timestamp: Time.current)
        Jil::Executor.call(user, AGENDA_ADD_CODE, data)
        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.kind).to eq("event")
        expect(item.name).to eq("Costco")
        expect(item.start_at).to be_within(2.seconds).of(Time.current)
        expect(item.end_at).to be_within(2.seconds).of(Time.current + 20.minutes)
      end
    end

    it "no duration, just name → TASK" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        ts = Time.zone.local(2026, 6, 18, 16, 0)
        data = agenda_add_data(rest: "buy milk", has_time: true, timestamp: ts)
        Jil::Executor.call(user, AGENDA_ADD_CODE, data)
        item = agenda.agenda_items.order(created_at: :desc).first
        expect(item.kind).to eq("task")
        expect(item.name).to eq("buy milk")
        # location falls back to remainder — harmless; geocoder won't resolve.
        expect(item.location).to eq("buy milk")
      end
    end

    it "stops propagation so other handlers don't double-respond" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        data = agenda_add_data(rest: "Costco for 20m", has_time: true, timestamp: Time.current)
        jil = Jil::Executor.call(user, AGENDA_ADD_CODE, data)
        expect(jil.ctx[:stop_propagation]).to be(true)
      end
    end
  end

  describe "Jarvis: Let's Go" do
    let(:ctrl) { instance_double(::TeslaControl) }
    before { allow(::TeslaControl).to receive(:me).and_return(ctrl) }

    it "navigates to a currently in-progress event" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 13, 30)) do
        agenda.agenda_items.create!(kind: :event, name: "Lunch", location: "The Cafe",
          start_at: Time.zone.local(2026, 6, 18, 13, 0),
          end_at:   Time.zone.local(2026, 6, 18, 14, 0))
        expect(ctrl).to receive(:navigate).with("The Cafe")
        jil = Jil::Executor.call(user, LETS_GO_CODE, {})
        expect(jil.ctx[:return_val]).to include("Lunch", "The Cafe")
      end
    end

    it "navigates to the next upcoming event when none is currently in progress" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        agenda.agenda_items.create!(kind: :event, name: "Costco run", location: "Costco",
          start_at: Time.zone.local(2026, 6, 18, 16, 0),
          end_at:   Time.zone.local(2026, 6, 18, 17, 0))
        expect(ctrl).to receive(:navigate).with("Costco")
        Jil::Executor.call(user, LETS_GO_CODE, {})
      end
    end

    it "skips items without a location" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        agenda.agenda_items.create!(kind: :event, name: "Stand-up", location: "",
          start_at: Time.zone.local(2026, 6, 18, 11, 0),
          end_at:   Time.zone.local(2026, 6, 18, 11, 30))
        agenda.agenda_items.create!(kind: :event, name: "Costco run", location: "Costco",
          start_at: Time.zone.local(2026, 6, 18, 16, 0),
          end_at:   Time.zone.local(2026, 6, 18, 17, 0))
        expect(ctrl).to receive(:navigate).with("Costco")
        Jil::Executor.call(user, LETS_GO_CODE, {})
      end
    end

    it "returns 'Nothing on the agenda' without invoking Tesla when nothing fits" do
      Timecop.freeze(Time.zone.local(2026, 6, 18, 10, 0)) do
        expect(::TeslaControl).not_to receive(:me)
        jil = Jil::Executor.call(user, LETS_GO_CODE, {})
        expect(jil.ctx[:return_val]).to eq("Nothing on the agenda")
      end
    end
  end

  describe "Jarvis: Add Stop" do
    let(:ctrl) { instance_double(::TeslaControl) }
    before { allow(::TeslaControl).to receive(:me).and_return(ctrl) }

    it "passes the captured dest to Tesla.addStop on success" do
      expect(ctrl).to receive(:add_stop).with("Costco").and_return(true)
      data = {
        words: "add stop Costco", full: "add stop Costco", has_time: false,
        timestamp: Time.current.iso8601, named_captures: { dest: "Costco" }
      }
      jil = Jil::Executor.call(user, ADD_STOP_CODE, data)
      expect(jil.ctx[:return_val]).to eq("Stop added: Costco")
    end

    it "surfaces a failure message when Tesla.addStop returns false" do
      expect(ctrl).to receive(:add_stop).with("Nowheresville").and_return(false)
      data = {
        words: "add stop Nowheresville", full: "add stop Nowheresville", has_time: false,
        timestamp: Time.current.iso8601, named_captures: { dest: "Nowheresville" }
      }
      jil = Jil::Executor.call(user, ADD_STOP_CODE, data)
      expect(jil.ctx[:return_val]).to eq("Couldn't add stop: Nowheresville")
    end
  end
end
