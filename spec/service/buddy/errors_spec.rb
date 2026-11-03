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

  def in_test
    allow(Rails.env).to receive_messages(development?: false, production?: false)
    allow(SlackWorker).to receive(:perform_async)
  end

  describe ".report" do
    it "writes a row tagged for Buddy and announces nothing outside production", :aggregate_failures do
      in_test

      expect {
        described_class.report(section: "test.section", exception: exception, user: user, extra: { id: 7 })
      }.to change(ErrorReport, :count).by(1)

      expect(ErrorReport.last).to have_attributes(
        section:     "test.section",
        error_class: "StandardError",
        message:     "boom",
        user_id:     user.id,
        extra:       { "id" => 7 },
        layer:       "backend",
        tag:         "buddy",
        channel:     nil,
      )
      expect(SlackWorker).not_to have_received(:perform_async)
    end

    it "announces in production with who it was for and a link to the row, and stamps the channel", :aggregate_failures do
      in_production

      described_class.report(section: "test.section", exception: exception, user: user)

      row = ErrorReport.last
      expect(SlackWorker).to have_received(:perform_async).with(
        include("test.section", "StandardError: boom", "##{user.id}", "/system/errors/#{row.id}"),
        described_class::SLACK_CHANNEL,
      )
      expect(row.channel).to eq(described_class::SLACK_CHANNEL)
    end

    it "announces a failure with no user attached" do
      in_production

      described_class.report(section: "test.section", exception: exception)

      expect(SlackWorker).to have_received(:perform_async).with(include("StandardError: boom"), described_class::SLACK_CHANNEL)
    end

    it "still announces when the row can't be written" do
      in_production
      allow(ErrorReport).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "gone")

      described_class.report(section: "test.section", exception: exception, user: user)

      expect(SlackWorker).to have_received(:perform_async).with(
        include("StandardError: boom"), described_class::SLACK_CHANNEL
      )
    end

    it "re-raises in development so failures cannot be missed" do
      allow(Rails.env).to receive_messages(development?: true, production?: false)

      expect {
        described_class.report(section: "test.section", exception: exception, user: user)
      }.to raise_error(StandardError, "boom")
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
