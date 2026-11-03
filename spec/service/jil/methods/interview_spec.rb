require "rails_helper"

RSpec.describe Jil::Methods::Interview do
  let(:owner) { User.me }
  let(:code) {
    <<~JIL
      out = Interview.prep(123)::Hash
      started = out.get("started")::Boolean
      state = out.get("state")::String
    JIL
  }
  let(:other) { FactoryBot.create(:user) }

  def run(user, code, auth: nil, auth_id: nil)
    Jil::Executor.call(user, code, {}, auth: auth, auth_id: auth_id)
  end

  def value(ctx, name)
    ctx.ctx[:vars][name][:value]
  end

  it "validates Interview.prep Jil" do
    expect { Jil::Validator.validate!(code) }.not_to raise_error
  end

  describe "#prep" do
    it "hands the agenda row to the prep and reports that it started" do
      expect(ByteInterviewPrep).to receive(:dispatch).with(owner, 123).and_return(:sent)

      ctx = run(owner, code)
      expect(value(ctx, :started)).to be(true)
      expect(value(ctx, :state)).to eq("sent")
    end

    # The listener casts a wide net on purpose - anything with "interview" in
    # the title - so "nothing to prep here" is an ordinary answer and has to be
    # readable as one rather than looking like a failure.
    it "says which branch it took when there was nothing to prep" do
      allow(ByteInterviewPrep).to receive(:dispatch).and_return(:not_an_interview)

      ctx = run(owner, code)
      expect(value(ctx, :started)).to be(false)
      expect(value(ctx, :state)).to eq("not_an_interview")
    end

    # A raise would abort the whole task. An interview is the one hour where a
    # half-run automation is worst, but it must never read as success either.
    it "reports a failure rather than raising" do
      allow(ByteInterviewPrep).to receive(:dispatch).and_raise("the Mac is asleep")

      ctx = run(owner, code)
      expect(value(ctx, :started)).to be(false)
      expect(value(ctx, :state)).to eq("the Mac is asleep")
    end

    it "refuses anyone but the owner without starting a session" do
      expect(ByteInterviewPrep).not_to receive(:dispatch)

      ctx = run(other, code)
      expect(value(ctx, :started)).to be(false)
    end
  end

  # A shared task runs as its OWNER, so `@jil.user` is him no matter who set it
  # off - and this reaches his own machine. These are the cases the owner check
  # alone lets straight through; same table as [Mac], now shared with it.
  describe "#prep when someone else set off a task of his" do
    before { allow(ByteInterviewPrep).to receive(:dispatch).and_return(:sent) }

    # FireDueAgendaTriggersWorker fires as `item.user`, so an interview on HER
    # calendar could match a task of his that is shared with her. An
    # actor-bearing execution that cannot name its actor is refused too.
    it "refuses another person's Run, companion, or agenda item, and an unnamed actor" do
      item = FactoryBot.create(:agenda_item, agenda: FactoryBot.create(:agenda, user: other))
      [[:run, other.id], [:buddy, other.id], [:agenda, item.id], [:run, nil]].each do |auth, auth_id|
        ctx = run(owner, code, auth: auth, auth_id: auth_id)
        expect(value(ctx, :started)).to be(false), "#{auth}/#{auth_id.inspect}"
      end
      expect(ByteInterviewPrep).not_to have_received(:dispatch)
    end

    # The -60 minute trigger arrives with no acting person at all, so the owner
    # check is the whole answer.
    it "still allows his own Run, the trigger, and cron" do
      [[:run, owner.id], [:trigger, 1234], [:cron, nil]].each do |auth, auth_id|
        ctx = run(owner, code, auth: auth, auth_id: auth_id)
        expect(value(ctx, :started)).to be(true), "#{auth}/#{auth_id.inspect}"
      end
    end
  end

  describe "the tasks that use it" do
    let(:schedule_code) {
      <<~JIL
        *evt = Global.input_data()::AgendaItem
        itemId = evt.id()::Numeric
        data = Hash.new({
          k1 = Keyval.new("id", itemId)::Keyval
        })::Hash
        sched = Global.trigger_for(evt, "interview-prep", -60, "minutes", "interview-prep", data)::Schedule
        join = Global.trigger_for(evt, "interview-join", -2, "minutes", "interview-join", data)::Schedule
      JIL
    }

    let(:prep_code) {
      <<~JIL
        *input = Global.input_data()::Hash
        itemId = input.get("id")::Numeric
        out = Interview.prep(itemId)::Hash
      JIL
    }

    let(:join_code) {
      <<~JIL
        *input = Global.input_data()::Hash
        itemId = input.get("id")::Numeric
        out = Interview.headsUp(itemId)::Hash
      JIL
    }

    it "validates all three" do
      expect { Jil::Validator.validate!(schedule_code) }.not_to raise_error
      expect { Jil::Validator.validate!(prep_code) }.not_to raise_error
      expect { Jil::Validator.validate!(join_code) }.not_to raise_error
    end

    # An hour before, and it has to FOLLOW the event: an interview moved by an
    # hour is the commonest thing that happens to one.
    it "hangs a -60 minute trigger off the event, carrying its id through to the prep" do
      agenda = FactoryBot.create(:agenda, user: owner)
      item = FactoryBot.create(
        :agenda_item,
        agenda: agenda, kind: :event, name: "Interview: Bluestaq",
        start_at: 3.days.from_now, end_at: 3.days.from_now + 1.hour
      )

      Jil::Executor.call(owner, schedule_code, { id: item.id })
      trigger = owner.scheduled_triggers.find_by(source_item_id: item.id, name: "interview-prep")

      expect(trigger.trigger).to eq("interview-prep")
      expect(trigger.execute_at).to be_within(1.second).of(item.start_at - 1.hour)
      expect(trigger.data["id"]).to eq(item.id)

      expect(ByteInterviewPrep).to receive(:dispatch).with(owner, item.id)
      Jil::Executor.call(owner, prep_code, { timestamp: trigger.execute_at }.merge(trigger.data))
    end

    it "writes no trigger for an interview already inside the hour" do
      agenda = FactoryBot.create(:agenda, user: owner)
      item = FactoryBot.create(
        :agenda_item,
        agenda: agenda, kind: :event, name: "Interview: Bluestaq",
        start_at: 20.minutes.from_now, end_at: 50.minutes.from_now
      )

      Jil::Executor.call(owner, schedule_code, { id: item.id })

      expect(owner.scheduled_triggers.where(source_item_id: item.id, name: "interview-prep")).to be_empty
    end

    # The brief's hour being gone says nothing about the two minutes: an
    # interview booked at short notice still wants its link.
    it "hangs a -2 minute heads-up off the same event, even inside the hour" do
      agenda = FactoryBot.create(:agenda, user: owner)
      item = FactoryBot.create(
        :agenda_item,
        agenda: agenda, kind: :event, name: "Interview: Bluestaq",
        start_at: 20.minutes.from_now, end_at: 50.minutes.from_now
      )

      Jil::Executor.call(owner, schedule_code, { id: item.id })
      trigger = owner.scheduled_triggers.find_by(source_item_id: item.id, name: "interview-join")

      expect(trigger.trigger).to eq("interview-join")
      expect(trigger.execute_at).to be_within(1.second).of(item.start_at - 2.minutes)
      expect(trigger.data["id"]).to eq(item.id)

      expect(ByteInterviewPrep::HeadsUp).to receive(:dispatch).with(owner, item.id).and_return(:link)
      ctx = Jil::Executor.call(owner, join_code, { timestamp: trigger.execute_at }.merge(trigger.data))
      expect(value(ctx, :out)).to eq({ "sent" => true, "state" => "link" })
    end
  end

  describe "#headsUp" do
    let(:code) {
      <<~JIL
        out = Interview.headsUp(123)::Hash
        sent = out.get("sent")::Boolean
        state = out.get("state")::String
      JIL
    }

    it "reports the link or phone branch as sent" do
      expect(ByteInterviewPrep::HeadsUp).to receive(:dispatch).with(owner, 123).and_return(:phone)

      ctx = run(owner, code)
      expect(value(ctx, :sent)).to be(true)
      expect(value(ctx, :state)).to eq("phone")
    end

    it "says nothing was sent for an onsite" do
      allow(ByteInterviewPrep::HeadsUp).to receive(:dispatch).and_return(:in_person)

      ctx = run(owner, code)
      expect(value(ctx, :sent)).to be(false)
      expect(value(ctx, :state)).to eq("in_person")
    end

    it "refuses another person pressing Run on a shared task" do
      expect(ByteInterviewPrep::HeadsUp).not_to receive(:dispatch)

      ctx = run(owner, code, auth: :run, auth_id: other.id)
      expect(value(ctx, :sent)).to be(false)
    end
  end
end
