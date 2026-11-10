require "rails_helper"

RSpec.describe ReceiveEmailWorker, type: :worker do
  describe "the worker" do
    let(:bucket) { "ardesian-emails" }
    let(:object_key) { "0fbk4c83djki6ol1v7d992kakp3ur7eq50sal501" }
    let(:content) { fixture("sample_raw_email.eml") }
    let(:mail) { ::Mail.new(content) }

    let(:user) { ::User.me }

    before do
      allow(FileStorage).to receive(:download).with(object_key, bucket: bucket).and_return(content)
      # Stub ActiveStorage blob attachment to avoid S3 SSL errors in test
      allow_any_instance_of(ActiveStorage::Attached::One).to receive(:attach).and_return(true)
      allow_any_instance_of(ActiveStorage::Attached::One).to receive(:blank?).and_return(true)
    end

    it "creates an Email with attached blob and correct attributes" do
      expect {
        described_class.new.perform(bucket, object_key, false)
      }.to change(Email, :count).by(1)

      email = Email.last
      # Mailboxes are stored as hashes with :address and :name keys via Emails::ParseMail
      from_addresses = email.outbound_mailboxes.map { |m| m.is_a?(Hash) ? (m[:address] || m["address"]) : m.to_s }
      to_addresses = email.inbound_mailboxes.map { |m| m.is_a?(Hash) ? (m[:address] || m["address"]) : m.to_s }
      expect(from_addresses).to contain_exactly(*Array.wrap(mail.from))
      expect(to_addresses).to match_array(Array.wrap(mail.to))
      expect(email.subject).to eq(mail.subject)
      expect(email.user_id).to eq(user.id)
    end
  end

  # Non-ASCII in both the subject and the body, and no Message-ID: the shape
  # that once raised after the row was written, so every retry saved a copy.
  describe "a mail with no Message-ID and non-ASCII text" do
    let(:bucket) { "ardesian-emails" }
    let(:object_key) { "no-id-#{SecureRandom.hex(4)}" }
    let(:content) {
      <<~EML
        From: Banka <info@example.ba>
        To: rocco@ardesian.com
        Subject: =?UTF-8?Q?Zahtjev_za_a=C5=BEuriranje_=E2=80=93_NBR?=
        Date: Mon, 9 Nov 2026 07:03:00 -0700
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: 8bit

        Poštovani, molimo ažurirajte podatke – hvala.
      EML
    }

    before do
      allow(FileStorage).to receive(:download).with(object_key, bucket: bucket).and_return(content)
      allow_any_instance_of(ActiveStorage::Attached::One).to receive(:attach).and_return(true)
      allow_any_instance_of(ActiveStorage::Attached::One).to receive(:blank?).and_return(true)
      allow(SlackNotifier).to receive(:notify)
      allow(JobMailTriageWorker).to receive(:perform_async)
    end

    it "announces it without raising" do
      expect { described_class.new.perform(bucket, object_key) }.not_to raise_error

      expect(SlackNotifier).to have_received(:notify).with(include("ažurirajte"), any_args)
    end

    it "lands a retry on the row the first attempt wrote" do
      expect {
        2.times { described_class.new.perform(bucket, object_key, false) }
      }.to change(Email, :count).by(1)
    end
  end

  describe "the Venmo trigger" do
    let(:bucket) { "ardesian-emails" }
    let(:object_key) { "venmo-chelsea-test-#{SecureRandom.hex(4)}" }
    let(:content) { fixture("venmo_chelsea_payment.eml") }
    let(:user) { ::User.me }

    let!(:task) {
      user.tasks.create!(
        name: "Test Venmo Chelsea Payment",
        listener: 'email:from:venmo subject:/Chelsea Haven paid you/',
        enabled: true,
        code: <<~'JIL'.strip,
          *input = Global.input_data()::Email
          email = Global.ref(input)::Email
          subject = email.subject()::String
          stop = Global.stop_propagation()::Boolean
        JIL
      )
    }

    before do
      allow(FileStorage).to receive(:download).with(object_key, bucket: bucket).and_return(content)
      allow_any_instance_of(ActiveStorage::Attached::One).to receive(:attach).and_return(true)
      allow_any_instance_of(ActiveStorage::Attached::One).to receive(:blank?).and_return(true)
      allow(SlackNotifier).to receive(:notify)
    end

    after { task.destroy }

    it "triggers the task when a matching Venmo email arrives" do
      ReceiveEmailWorker.new.perform(bucket, object_key, false)
      email = Email.last
      expect(email.subject).to eq("Chelsea Haven paid you $1.00")

      results = ::Jil.trigger(user, :email, email)
      triggered_names = results.map(&:name)

      expect(triggered_names).to include(task.name)
    end
  end
end
