require "rails_helper"

# Anchors exist so a schedule can hang off a moving time WITHOUT anyone editing
# Ruby. That only holds if a Jil task can create and feed one, which is what
# these cover.
RSpec.describe "Jil: Anchor", type: :service do
  let(:user) { create(:user) }
  let(:tz) { ActiveSupport::TimeZone[user.timezone] }
  let(:tonight) { tz.local(2026, 8, 19, 20, 24) }

  def run(code)
    Jil::Executor.call(user, code).tap { |result|
      expect(result.ctx[:error]).to be_nil, "Jil error: #{result.ctx[:error].inspect}"
    }
  end

  it "creates the anchor on first write" do
    run(<<~'JIL')
      at = Date.new(2026, 8, 19, 20, 24)::Date
      a = Anchor.set("sun:sunset", at, "2026-08-19")::Anchor
      out = Global.return(a)::Hash
    JIL

    anchor = Anchor.for(user, "sun:sunset")
    expect(anchor).to be_present
    expect(anchor.occurrences.sole.occurs_at).to be_within(1.second).of(tonight)
    expect(anchor.occurrences.sole.identifier).to eq("2026-08-19")
  end

  it "makes a brand new key usable in a cron immediately" do
    run(<<~'JIL')
      at = Date.new(2026, 8, 20, 7, 0)::Date
      a = Anchor.set("trash:pickup", at, "2026-08-20")::Anchor
      out = Global.return(a)::Hash
    JIL

    task = user.tasks.create!(
      name: "Bins", listener: "tell:bins", code: "// noop", enabled: true,
      cron: "trash:pickup-30m",
    )

    expect(task).to be_valid
    expect(task.next_trigger_at).to be_within(1.second).of(tz.local(2026, 8, 20, 6, 30))
  end

  it "replaces the occurrence when the same identifier is written again" do
    ["20, 24", "20, 34"].each do |clock|
      run(<<~JIL)
        at = Date.new(2026, 8, 19, #{clock})::Date
        a = Anchor.set("sun:sunset", at, "2026-08-19")::Anchor
        out = Global.return(a)::Hash
      JIL
    end

    anchor = Anchor.for(user, "sun:sunset")
    expect(anchor.occurrences.count).to eq(1)
    expect(anchor.occurrences.sole.occurs_at).to be_within(1.second).of(tonight + 10.minutes)
  end

  it "appends when no identifier is given" do
    [19, 20].each do |day|
      run(<<~JIL)
        at = Date.new(2026, 8, #{day}, 20, 24)::Date
        a = Anchor.set("sun:sunset", at)::Anchor
        out = Global.return(a)::Hash
      JIL
    end

    expect(Anchor.for(user, "sun:sunset").occurrences.count).to eq(2)
  end

  it "removes one occurrence and keeps the anchor" do
    anchor = user.anchors.create!(key: "sun:sunset")
    anchor.set_occurrence(tonight, identifier: "keep")
    anchor.set_occurrence(tonight + 1.day, identifier: "drop")

    run(<<~'JIL')
      gone = Anchor.remove("sun:sunset", "drop")::Boolean
      out = Global.return(gone)::Boolean
    JIL

    expect(anchor.occurrences.reload.pluck(:identifier)).to eq(["keep"])
    expect(Anchor.for(user, "sun:sunset")).to be_present
  end

  it "clears every occurrence but leaves the anchor valid for a cron" do
    anchor = user.anchors.create!(key: "sun:sunset")
    anchor.set_occurrence(tonight, identifier: "a")

    run(<<~'JIL')
      done = Anchor.clear("sun:sunset")::Boolean
      out = Global.return(done)::Boolean
    JIL

    expect(anchor.occurrences.reload).to be_empty
    expect(Anchor.for(user, "sun:sunset")).to be_present
  end

  it "answers what a cron of the same string would" do
    user.anchors.create!(key: "sun:sunset").set_occurrence(tonight, identifier: "a")

    result = travel_to(tz.local(2026, 8, 19, 12, 0)) do
      run(<<~'JIL')
        at = Anchor.next("sun:sunset-5m")::Date
        out = Global.return(at)::Date
      JIL
    end

    expect(Time.parse(result.ctx[:return_val].to_s)).to be_within(1.second).of(tonight - 5.minutes)
  end

  it "re-resolves a dependent task as a side effect of the write" do
    user.anchors.create!(key: "sun:sunset").set_occurrence(tonight, identifier: "2026-08-19")
    task = travel_to(tz.local(2026, 8, 19, 12, 0)) do
      user.tasks.create!(
        name: "Porch", listener: "tell:porch", code: "// noop", enabled: true,
        cron: "sun:sunset-5m",
      )
    end

    travel_to(tz.local(2026, 8, 19, 12, 0)) do
      run(<<~'JIL')
        at = Date.new(2026, 8, 19, 20, 42)::Date
        a = Anchor.set("sun:sunset", at, "2026-08-19")::Anchor
        out = Global.return(a)::Hash
      JIL
    end

    expect(task.reload.next_trigger_at).to be_within(1.second).of(tonight + 13.minutes)
  end

  it "won't create an anchor from a key that isn't domain:event" do
    run(<<~'JIL')
      at = Date.new(2026, 8, 19, 20, 24)::Date
      a = Anchor.set("sunset", at)::Anchor
      out = Global.return(a)::Hash
    JIL

    expect(user.anchors.reload).to be_empty
  end
end
