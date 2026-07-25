require "rails_helper"

RSpec.describe Buddy::Errors do
  let(:user) { User.create!(username: "err-#{SecureRandom.hex(4)}", password: "abcd1234!", password_confirmation: "abcd1234!") }
  let(:exception) { StandardError.new("boom").tap { |e| e.set_backtrace(["line1", "line2", "line3"]) } }

  describe ".report" do
    it "logs at ERROR with section, class, message, and a backtrace slice" do
      allow(Rails.env).to receive(:development?).and_return(false)  # avoid re-raise
      allow(Rails.logger).to receive(:error)

      described_class.report(section: "test.section", exception: exception, user: user)

      expect(Rails.logger).to have_received(:error) { |msg|
        expect(msg).to include("test.section")
        expect(msg).to include("StandardError: boom")
        expect(msg).to include("user=#{user.id}")
        expect(msg).to include("line1")
      }
    end

    it "re-raises in development so failures cannot be missed" do
      allow(Rails.env).to receive(:development?).and_return(true)
      allow(Rails.env).to receive(:production?).and_return(false)

      expect {
        described_class.report(section: "test.section", exception: exception, user: user)
      }.to raise_error(StandardError, "boom")
    end

    it "pings Slack asynchronously via SlackWorker in production" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:production?).and_return(true)
      stub_const("SlackWorker::WEBHOOK_URL", "https://example.com/hook")
      allow(SlackWorker).to receive(:perform_async)

      described_class.report(section: "test.section", exception: exception, user: user)

      expect(SlackWorker).to have_received(:perform_async).with(
        include("Buddy test.section failed", "user=#{user.id}", "StandardError: boom"),
        described_class::SLACK_CHANNEL,
      )
    end

    it "does NOT ping Slack in development / test" do
      allow(Rails.env).to receive(:development?).and_return(false)  # avoid re-raise
      allow(Rails.env).to receive(:production?).and_return(false)
      allow(SlackWorker).to receive(:perform_async)

      described_class.report(section: "test.section", exception: exception, user: user)

      expect(SlackWorker).not_to have_received(:perform_async)
    end

    it "swallows failures thrown by the reporter itself so caller isn't affected" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.logger).to receive(:error).and_raise("logger down")

      expect {
        described_class.report(section: "test.section", exception: exception, user: user)
      }.not_to raise_error
    end
  end
end
