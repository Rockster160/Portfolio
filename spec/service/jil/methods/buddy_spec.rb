require "rails_helper"

RSpec.describe "Jil Buddy method" do
  let(:user) { User.me }

  it "validates Buddy.say / Buddy.prompt Jil" do
    code = <<~'JIL'
      a1 = Buddy.say("Trash goes out tonight")::Boolean
      a2 = Buddy.prompt("remind them trash night is tonight, keep it light")::Boolean
    JIL
    expect { Jil::Validator.validate!(code) }.not_to raise_error
  end

  it "Buddy.say drops a verbatim inbound message + pushes" do
    convo = double("conversation")
    allow(Buddy::CompanionRelay).to receive(:conversation_for).with(user).and_return(convo)

    expect(Buddy::CompanionDelivery).to receive(:deliver_plain).with(
      user:         user,
      conversation: convo,
      text:         "Trash goes out tonight",
      metadata:     { kind: "buddy", source: "jil" },
      push_title:   "Trash goes out tonight",
    )

    ctx = Jil::Executor.call(user,
      <<~'JIL',
        out = Buddy.say("Trash goes out tonight")::Boolean
      JIL
    )
    expect(ctx.ctx[:vars][:out][:value]).to be(true)
  end

  it "Buddy.prompt seeds an in-character turn tagged buddy_trigger" do
    convo = double("conversation")
    allow(Buddy::CompanionRelay).to receive(:conversation_for).with(user).and_return(convo)

    expect(Buddy::CompanionDelivery).to receive(:deliver_prompt).with(
      user:         user,
      conversation: convo,
      seed:         "let them know the wash is done",
      metadata:     { kind: "buddy_trigger", hidden: true, source: "jil" },
    )

    Jil::Executor.call(user,
      <<~'JIL',
        p1 = Buddy.prompt("let them know the wash is done")::Boolean
      JIL
    )
  end

  it "returns false and delivers nothing on a blank message" do
    expect(Buddy::CompanionDelivery).not_to receive(:deliver_plain)

    ctx = Jil::Executor.call(user,
      <<~'JIL',
        out = Buddy.say("   ")::Boolean
      JIL
    )
    expect(ctx.ctx[:vars][:out][:value]).to be(false)
  end
end
