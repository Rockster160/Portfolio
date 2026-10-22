require "rails_helper"

# Buddy reads mail through the emails page's own search, reaching the archive
# by default, and opens one message by id. Nothing it does changes the mail.
RSpec.describe "search_email tool" do
  let(:user)   { create(:user) }
  let(:other)  { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  def mail(owner=user, **attrs)
    from = attrs.delete(:from) || { name: "Brightwater Vet", address: "front@brightwater.example" }
    Email.create!(
      user:               owner,
      mail_id:            SecureRandom.hex(8),
      timestamp:          attrs.delete(:at) || 1.day.ago,
      direction:          attrs.delete(:direction) || :inbound,
      inbound_mailboxes:  [{ name: nil, address: "me@ardesian.com" }],
      outbound_mailboxes: [from],
      subject:            "Lab results",
      blurb:              "Juniper's bloodwork came back.",
      **attrs,
    )
  end

  def run(payload)
    Buddy::GPT::Turn.resolve_call(
      Buddy::Tools[:search_email],
      { name: "search_email", arguments: payload, call_id: "c1" },
      user: user, conversation: convo,
    ).first
  end

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  it "finds mail by sender, archived or not, and only this person's" do
    filed = mail(archived_at: 1.hour.ago)
    mail(other)
    mail(from: { name: "Bank", address: "alerts@bank.example" }, subject: "Statement")

    result = run({ from: "vet" })

    expect(result[:emails].pluck(:id)).to eq([filed.id])
    expect(result[:emails].first).to include(from: "Brightwater Vet <front@brightwater.example>", subject: "Lab results", archived: true)
    expect(result[:searched]).to eq("from:vet")
  end

  it "stays on received mail until a direction is named" do
    received = mail
    sent = mail(direction: :outbound, subject: "Lab results question")

    expect(run({ query: "lab" })[:emails].pluck(:id)).to eq([received.id])
    expect(run({ query: "lab in:sent" })[:emails].pluck(:id)).to eq([sent.id])
  end

  it "compiles subject and dates into the search syntax" do
    old = mail(at: 20.days.ago)
    recent = mail(at: 2.days.ago)
    mail(subject: "Appointment reminder", at: 2.days.ago)

    result = run({ subject: "lab results", after: 5.days.ago.to_date.iso8601 })

    expect(result[:emails].pluck(:id)).to eq([recent.id])
    expect(result[:emails].pluck(:id)).not_to include(old.id)
  end

  it "keeps every alternative of an OR inside the same scope" do
    vet = mail(subject: "Re: bloodwork")
    mail(direction: :outbound, subject: "Juniper question")
    mail(other, subject: "Juniper")

    result = run({ query: "Juniper OR bloodwork", after: 5.days.ago.to_date.iso8601 })

    expect(result[:emails].pluck(:id)).to eq([vet.id])
  end

  it "holds the fields to every alternative of an OR, not just the last" do
    vet = mail(subject: "Pickles bloodwork")
    mail(from: { name: "Lab Corp", address: "noreply@lab.example" }, subject: "bloodwork Pickles")

    result = run({ query: "Pickles bloodwork OR bloodwork Pickles", from: "brightwater" })

    expect(result[:emails].pluck(:id)).to eq([vet.id])
  end

  it "drops a sender that matched nothing when the words alone find the mail" do
    vet = mail(from: { name: "Brightwater Animal Clinic", address: "front@brightwater.example" }, subject: "Pickles bloodwork")

    result = run({ query: "Pickles", from: "vet" })

    expect(result[:emails].pluck(:id)).to eq([vet.id])
    expect(result[:dropped]).to start_with("from:vet matched nothing")
    expect(result[:searched]).to eq("Pickles")
  end

  it "keeps the sender when nothing matches either way" do
    result = run({ query: "Pickles", from: "vet" })

    expect(result[:emails]).to be_empty
    expect(result[:dropped]).to be_nil
  end

  it "narrows to archived mail when asked" do
    mail(archived_at: 1.hour.ago)
    live = mail

    expect(run({ query: "is:unarchived vet" })[:emails].pluck(:id)).to eq([live.id])
    expect(run({ query: "is:archived vet" })[:emails].pluck(:id)).not_to include(live.id)
  end

  it "says what it couldn't read when nothing matches" do
    result = run({ query: "after:notadate" })

    expect(result[:emails]).to be_empty
    expect(result[:how]).to include("couldn't find it")
  end

  it "reads one message in full without marking it read" do
    email = mail
    allow(Buddy::JobMailOffer).to receive(:mail_text).with(email).and_return("Her levels are normal. Recheck in 6 months.")

    result = run({ id: email.id })

    expect(result[:email]).to include(id: email.id, text: "Her levels are normal. Recheck in 6 months.", link: "/emails/#{email.id}")
    expect(email.reload.read_at).to be_nil
  end

  it "falls back to the stored opening when the body can't be fetched" do
    email = mail
    allow(Buddy::JobMailOffer).to receive(:mail_text).and_return(nil)

    expect(run({ id: email.id })[:email]).to include(text: "Juniper's bloodwork came back.", partial: true)
  end

  it "refuses someone else's mail" do
    theirs = mail(other)

    expect(run({ id: theirs.id }).to_s).to include("No email ##{theirs.id}")
  end

  it "is only offered to someone holding the email feature" do
    user.update!(buddy_features: Buddy::Features::DEFAULT - [:email])
    expect(Buddy::Features.allows_tool?(user, Buddy::Tools[:search_email])).to be(false)

    user.update!(buddy_features: Buddy::Features::DEFAULT)
    expect(Buddy::Features.allows_tool?(user, Buddy::Tools[:search_email])).to be(true)
  end
end
