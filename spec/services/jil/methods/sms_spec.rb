RSpec.describe Jil::Methods::Sms do
  include ActiveJob::TestHelper

  let(:execute) { Jil::Executor.call(user, code, input_data) }
  let(:user) { User.me }
  let(:input_data) { {} }
  let(:ctx) { execute.ctx }

  describe "schema registration" do
    it "validates Sms.deliver against the schema" do
      code = "ok = Sms.deliver(\"hi\")::Boolean\n"
      expect { Jil::Validator.validate!(code) }.not_to raise_error
    end
  end

  describe "#deliver" do
    let(:code) {
      <<~JIL
        ok = Sms.deliver("hello there")::Boolean
      JIL
    }

    it "enqueues an SMS to the executing user's phone" do
      allow(user).to receive(:phone).and_return("3855551234")
      expect(::SmsWorker).to receive(:perform_async).with("3855551234", "hello there")

      expect_successful_jil

      expect(ctx[:vars][:ok][:value]).to eq(true)
    end

    context "when the user has no phone" do
      before { allow(user).to receive(:phone).and_return("") }

      it "does not enqueue and returns false" do
        expect(::SmsWorker).not_to receive(:perform_async)

        expect_successful_jil

        expect(ctx[:vars][:ok][:value]).to eq(false)
      end
    end

    context "when the message is blank" do
      let(:code) {
        <<~JIL
          ok = Sms.deliver("")::Boolean
        JIL
      }

      it "does not enqueue and returns false" do
        expect(::SmsWorker).not_to receive(:perform_async)

        expect_successful_jil

        expect(ctx[:vars][:ok][:value]).to eq(false)
      end
    end
  end
end
