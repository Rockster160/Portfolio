RSpec.describe "Venmo Chelsea email trigger", type: :worker do
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

    results = ::Jil.trigger_now(user, :email, email)
    triggered_names = results.map(&:name)

    expect(triggered_names).to include(task.name)
  end
end
