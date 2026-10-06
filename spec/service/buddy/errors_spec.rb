require "rails_helper"

RSpec.describe Buddy::Errors do
  let(:user) { User.create!(username: "err-#{SecureRandom.hex(4)}", password: "abcd1234!", password_confirmation: "abcd1234!") }
  let(:exception) { StandardError.new("boom").tap { |e| e.set_backtrace(["line1", "line2", "line3"]) } }

  # Production with a webhook, which is the only state that announces.
  def in_production
    allow(Rails.env).to receive_messages(development?: false, production?: true)
    stub_const("SlackWorker::WEBHOOK_URL", "https://example.com/hook")
    allow(SlackWorker).to receive(:perform_async)
  end

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
        include("Buddy test.section failed", "StandardError: boom"),
        described_class::SLACK_CHANNEL,
      )
    end

    # An id on its own answers a question nobody asked. The alert has to say
    # whose failure this was without anyone going and looking the number up.
    it "names who it happened for" do
      in_production

      described_class.report(section: "test.section", exception: exception, user: user)

      expect(SlackWorker).to have_received(:perform_async).with(
        include("for #{user.first_name} (##{user.id})"), described_class::SLACK_CHANNEL
      )
    end

    it "says plainly when there was nobody attached to it" do
      in_production

      described_class.report(section: "test.section", exception: exception)

      expect(SlackWorker).to have_received(:perform_async).with(
        include("for nobody"), described_class::SLACK_CHANNEL
      )
    end

    # The alert ends at the row, so the rest of the failure is one tap away
    # instead of being whatever fitted in a message.
    it "links the row it just wrote" do
      in_production

      described_class.report(section: "test.section", exception: exception, user: user)

      expect(SlackWorker).to have_received(:perform_async).with(
        include("/system/errors/#{ErrorReport.last.id}"), described_class::SLACK_CHANNEL
      )
    end

    # The announcement is the part somebody is waiting on, so it is never
    # downstream of a write succeeding.
    it "still pings Slack when the row can't be written" do
      in_production
      allow(ErrorReport).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "gone")

      described_class.report(section: "test.section", exception: exception, user: user)

      expect(SlackWorker).to have_received(:perform_async).with(
        include("StandardError: boom"), described_class::SLACK_CHANNEL
      )
    end

    it "does NOT ping Slack in development / test" do
      allow(Rails.env).to receive(:development?).and_return(false)  # avoid re-raise
      allow(Rails.env).to receive(:production?).and_return(false)
      allow(SlackWorker).to receive(:perform_async)

      described_class.report(section: "test.section", exception: exception, user: user)

      expect(SlackWorker).not_to have_received(:perform_async)
    end

    # The ping interrupts; the row is what can still be counted tomorrow.
    it "writes a row for the failure as well as logging it" do
      allow(Rails.env).to receive(:development?).and_return(false)

      expect {
        described_class.report(section: "test.section", exception: exception, user: user, extra: { id: 7 })
      }.to change(ErrorReport, :count).by(1)

      row = ErrorReport.last
      expect(row.section).to eq("test.section")
      expect(row.error_class).to eq("StandardError")
      expect(row.message).to eq("boom")
      expect(row.user_id).to eq(user.id)
      expect(row.extra).to eq({ "id" => 7 })
    end

    # A failure nothing announced is the kind nobody has seen, and the row is
    # the only place that difference survives.
    it "says on the row whether anything was announced" do
      in_production

      described_class.report(section: "test.section", exception: exception, user: user)
      expect(ErrorReport.last.channel).to eq(described_class::SLACK_CHANNEL)
    end

    it "records a failure that was never announced anywhere" do
      allow(Rails.env).to receive_messages(development?: false, production?: false)

      described_class.report(section: "test.section", exception: exception, user: user)
      expect(ErrorReport.last.channel).to be_nil
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
