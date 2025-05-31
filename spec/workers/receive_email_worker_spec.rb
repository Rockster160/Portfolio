RSpec.describe ReceiveEmailWorker, type: :worker do
  let(:bucket) { "ardesian-emails" }
  let(:object_key) { "0fbk4c83djki6ol1v7d992kakp3ur7eq50sal501" }
  let(:content) { fixture("sample_raw_email.eml") }
  let(:mail) { ::Mail.new(content) }

  let(:user) { ::User.me }

  before do
    allow(FileStorage).to receive(:download).with(object_key, bucket: bucket).and_return(content)
  end

  it "creates an Email with attached blob and correct attributes" do
    expect {
      described_class.new.perform(bucket, object_key)
    }.to change { Email.count }.by(1)

    email = Email.last
    expect(email.outbound_mailboxes).to match_array([mail.from_address.to_s])
    expect(email.inbound_mailboxes).to match_array(mail.to_addresses.map(&:to_s))
    expect(email.subject).to eq(mail.subject)
    expect(email.user_id).to eq(user.id)
    expect(email.mail_blob).to be_attached
  end
end
