require "rails_helper"

RSpec.describe Jil::Methods::Mac do
  let(:owner)  { User.me }
  let(:other)  { FactoryBot.create(:user) }

  def run(user, code, auth: nil, auth_id: nil)
    Jil::Executor.call(user, code, {}, auth: auth, auth_id: auth_id)
  end

  def value(ctx, name)
    ctx.ctx[:vars][name][:value]
  end

  # schema.txt is a flat file, so the enum can't be derived from the registry it
  # mirrors. This is what makes a new Mac command that skipped the schema loud
  # instead of merely unreachable from the Jil editor.
  it "lists exactly ByteLocal::MAC_COMMANDS in the [Mac] schema enum" do
    line = File.readlines(Jil::Validator.schema_path).each_cons(2).detect { |a, _b|
      a.match?(/^\[Mac\]/)
    }&.last
    names = line.to_s[/\[(.*?)\]/, 1].to_s.scan(/"([^"]+)"/).flatten.map(&:to_sym)

    expect(names).to eq(ByteLocal::MAC_COMMANDS.keys)
  end

  it "validates Mac.run Jil" do
    code = <<~'JIL'
      out = Mac.run("dark_monitors")::Hash
    JIL
    expect { Jil::Validator.validate!(code) }.not_to raise_error
  end

  describe "#run" do
    it "sends the command name to the Mac and returns its answer" do
      expect(ByteLocal).to receive(:run_command).with("dark_monitors").and_return(
        { ok: true, name: "dark_monitors", output: "", exit_status: 0 },
      )

      ctx = run(owner, <<~'JIL')
        out = Mac.run("dark_monitors")::Hash
        ok = out.get("ok")::Boolean
      JIL
      expect(value(ctx, :ok)).to be(true)
    end

    it "keeps the command's output reachable" do
      allow(ByteLocal).to receive(:run_command).and_return(
        { ok: true, name: "mac_ping", output: "awake on Desk at 9:04 AM", exit_status: 0 },
      )

      ctx = run(owner, <<~'JIL')
        res = Mac.run("mac_ping")::Hash
        said = res.get("output")::String
      JIL
      expect(value(ctx, :said)).to eq("awake on Desk at 9:04 AM")
    end

    # A raise here would abort the whole task; an unreachable Mac shouldn't take
    # the rest of an automation with it, but it must never read as success.
    it "reports a sleeping Mac as a failure rather than raising" do
      allow(ByteLocal).to receive(:run_command).and_raise("couldn't reach the laptop - it may be asleep")

      ctx = run(owner, <<~'JIL')
        out = Mac.run("dark_monitors")::Hash
        ok = out.get("ok")::Boolean
        why = out.get("error")::String
      JIL
      expect(value(ctx, :ok)).to be(false)
      expect(value(ctx, :why)).to eq("couldn't reach the laptop - it may be asleep")
    end

    it "refuses anyone but the owner without touching the Mac" do
      expect(ByteLocal).not_to receive(:run_command)

      ctx = run(other, <<~'JIL')
        out = Mac.run("dark_monitors")::Hash
        ok = out.get("ok")::Boolean
      JIL
      expect(value(ctx, :ok)).to be(false)
    end
  end

  # A shared task runs as its OWNER, so `@jil.user` is me no matter who set it
  # off. These are the cases the owner check alone lets straight through.
  describe "#run when someone else set off a task of mine" do
    let(:code) {
      <<~'JIL'
        out = Mac.run("dark_monitors")::Hash
        ok = out.get("ok")::Boolean
      JIL
    }

    before { allow(ByteLocal).to receive(:run_command).and_return({ ok: true }) }

    # FireDueAgendaTriggersWorker fires as `item.user`, so an item on HER
    # calendar can match a task of mine that's shared with her.
    it "refuses another person's Run, companion, or agenda item, and an unnamed actor" do
      item = FactoryBot.create(:agenda_item, agenda: FactoryBot.create(:agenda, user: other))
      [[:run, other.id], [:buddy, other.id], [:agenda, item.id], [:run, nil]].each do |auth, auth_id|
        ctx = run(owner, code, auth: auth, auth_id: auth_id)
        expect(value(ctx, :ok)).to be(false), "#{auth}/#{auth_id.inspect}"
      end
      expect(ByteLocal).not_to have_received(:run_command)
    end

    # `cron` and `words` carry no acting person, so the owner check is the
    # whole answer for them.
    it "still allows my own agenda item, Run, companion, cron and voice command" do
      item = FactoryBot.create(:agenda_item, agenda: FactoryBot.create(:agenda, user: owner))
      [[:agenda, item.id], [:run, owner.id], [:buddy, owner.id], [:cron, nil], [:words, nil]].each do |auth, auth_id|
        ctx = run(owner, code, auth: auth, auth_id: auth_id)
        expect(value(ctx, :ok)).to be(true), "#{auth}/#{auth_id.inspect}"
      end
    end
  end
end
