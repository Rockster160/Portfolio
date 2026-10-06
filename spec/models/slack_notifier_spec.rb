require "rails_helper"

# Which Slack pings are failures, and how that gets decided without every
# caller having to say.
RSpec.describe SlackNotifier do
  before { allow(described_class).to receive(:puts) }

  describe ".notify" do
    # A ping sent from inside a rescue is a failure report whatever its
    # wording, and `$!` is what says so - it holds the exception for the whole
    # of the rescue, including the frames the rescue calls into.
    it "records a ping sent while an exception is being handled" do
      expect {
        begin
          raise ArgumentError, "printer refused"
        rescue StandardError
          described_class.notify("Failed to request from PrinterControl#get(/status)")
        end
      }.to change(ErrorReport, :count).by(1)

      row = ErrorReport.last
      expect(row.error_class).to eq("ArgumentError")
      expect(row.message).to include("printer refused")
      expect(row.message).to include("Failed to request from PrinterControl")
      # Nothing left the process in this environment, so nothing is stamped as
      # announced - which is what keeps `channel` honest.
      expect(row.channel).to be_nil
    end

    # Mail landing and an SMS arriving are the bulk of this channel and neither
    # is a failure. They are not sent from a rescue, which is the whole of the
    # distinction.
    it "leaves an ordinary ping alone" do
      expect {
        described_class.notify("received email from somebody", channel: "#portfolio")
      }.not_to change(ErrorReport, :count)
    end

    it "names the file and line that was reporting" do
      begin
        raise "boom"
      rescue StandardError
        described_class.notify("something went wrong")
      end

      expect(ErrorReport.last.section).to match(/\Aslack_notifier_spec:\d+\z/)
    end

    it "still pings the channel it was going to ping" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(SlackWorker).to receive(:perform_async)

      begin
        raise "boom"
      rescue StandardError
        described_class.notify("something went wrong", channel: "#zygy-alerts")
      end

      expect(SlackWorker).to have_received(:perform_async).with(
        include("something went wrong"), "#zygy-alerts", "Portfolio-Bot", ":blackmage:", []
      )
    end
  end

  describe "what the alert says" do
    # An id on its own answers a question nobody asked; most of these pings had
    # no user on them at all.
    it "names who it happened for" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(SlackWorker).to receive(:perform_async)
      user = create(:user)

      begin
        raise "boom"
      rescue StandardError
        described_class.notify("push failed", user: user)
      end

      expect(SlackWorker).to have_received(:perform_async).with(
        include("— #{user.first_name} (##{user.id})"), any_args
      )
    end

    it "ends at a link to the row" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(SlackWorker).to receive(:perform_async)

      begin
        raise "boom"
      rescue StandardError
        described_class.notify("push failed")
      end

      expect(SlackWorker).to have_received(:perform_async).with(
        include("/system/errors/#{ErrorReport.last.id}"), any_args
      )
    end

    # The alert is the part somebody is waiting on, so it is never downstream
    # of a write succeeding - and it still has to say who.
    it "still announces, with the name on it, when the row can't be written" do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(SlackWorker).to receive(:perform_async)
      allow(ErrorReport).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "gone")
      user = create(:user)

      begin
        raise "boom"
      rescue StandardError
        described_class.notify("push failed", user: user)
      end

      expect(SlackWorker).to have_received(:perform_async).with(
        include("push failed", "(##{user.id})"), any_args
      )
    end
  end

  # A channel filling up with one incident is a channel nobody reads, so the
  # repeats are held back - and the row is still written for every one of them.
  describe "a failure that keeps happening" do
    before do
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(SlackWorker).to receive(:perform_async)
    end

    def ping(message="printer refused the job")
      raise ArgumentError, "printer offline"
    rescue StandardError
      described_class.notify(message)
    end

    it "announces the first one and stamps it as announced" do
      ping

      expect(SlackWorker).to have_received(:perform_async).once
      expect(ErrorReport.last.channel).to eq("#portfolio")
    end

    it "holds back the repeats while it is still going" do
      4.times { ping }

      expect(SlackWorker).to have_received(:perform_async).once
      expect(ErrorReport.count).to eq(4)
      expect(ErrorReport.where.not(channel: nil).count).to eq(1)
    end

    # Starting again after it had stopped is news, and says so.
    it "speaks up again after a break" do
      travel_to(2.hours.ago) { ping }

      ping

      expect(SlackWorker).to have_received(:perform_async).twice
      expect(SlackWorker).to have_received(:perform_async).with(include("back after"), any_args)
    end

    # Suppressed is not swallowed: one that never stops still gets said again,
    # carrying everything held back since. Every 20 minutes, so no gap is long
    # enough to count as a break and it is the same incident throughout.
    it "says so again when it has been going for hours, with the count" do
      [150, 130, 110, 90, 70, 50].each { |ago| travel_to(ago.minutes.ago) { ping } }

      travel_to(30.minutes.ago) { ping }

      expect(SlackWorker).to have_received(:perform_async).twice
      expect(SlackWorker).to have_received(:perform_async).with(
        include("still going", "of these in the"), any_args
      )
    end

    it "announces one that has happened before but was never announced" do
      travel_to(5.minutes.ago) { ErrorReport.record!(section: "x", message: "printer refused the job") }

      ping

      expect(SlackWorker).to have_received(:perform_async).once
    end

    # Two failures that aren't the same one don't quiet each other.
    it "keeps separate failures separate" do
      ping("printer refused the job")
      ping("the scanner refused the job")

      expect(SlackWorker).to have_received(:perform_async).twice
    end
  end

  describe ".err" do
    # It is handed the exception, so it says so rather than relying on where it
    # was called from.
    it "records the exception it was given" do
      exception = RuntimeError.new("Traveltime failed").tap { |e| e.set_backtrace(["/app/service/address_book.rb:163"]) }

      user = create(:user)

      expect { described_class.err(exception, "Traveltime failed: ", user: user) }
        .to change(ErrorReport, :count).by(1)
      expect(ErrorReport.last.error_class).to eq("RuntimeError")
      expect(ErrorReport.last.user_id).to eq(user.id)
    end
  end
end
