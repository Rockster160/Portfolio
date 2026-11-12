require "rails_helper"

RSpec.describe ProductionScripts do
  let(:user) { User.me }
  let(:head) { `git -C #{Rails.root} rev-parse HEAD`.strip }
  let(:unknown) { "0" * 40 }
  let(:script) {
    described_class.create!(user: user, title: "Fix it", code: "puts 1", commit_sha: head, edited_by: :mini)
  }

  before { allow(ProductionScriptRunWorker).to receive(:perform_async) }

  describe ".deployed?" do
    it "knows a commit that is part of what's running from one that isn't" do
      expect(described_class.deployed?(head)).to be(true)
      expect(described_class.deployed?(unknown)).to be(false)
      expect(described_class.deployed?("not a sha")).to be(false)
    end
  end

  describe ".approve!" do
    it "runs it now when its commit is already deployed" do
      described_class.approve!(script, by: user)

      expect(script.reload).to be_status_approved
      expect(ProductionScriptRunWorker).to have_received(:perform_async).with(script.id)
    end

    it "holds it for the deploy that brings its commit in" do
      script.update!(commit_sha: unknown)

      described_class.approve!(script, by: user)

      expect(script.reload).to be_status_approved
      expect(ProductionScriptRunWorker).not_to have_received(:perform_async)
    end

    it "takes approval from the owner only" do
      expect { described_class.approve!(script, by: FactoryBot.create(:user)) }.to raise_error(ArgumentError)
      expect(script.reload).to be_status_pending
    end
  end

  describe ".run_deployed!" do
    it "runs the approved scripts the deploy brought in, and leaves the rest" do
      waiting = described_class.create!(user: user, title: "Later", code: "1", commit_sha: unknown, edited_by: :mini)
      [script, waiting].each { |each_script| each_script.update!(status: :approved) }
      unapproved = described_class.create!(user: user, title: "No", code: "1", commit_sha: head, edited_by: :mini)

      described_class.run_deployed!

      expect(ProductionScriptRunWorker).to have_received(:perform_async).with(script.id).once
      expect(ProductionScriptRunWorker).not_to have_received(:perform_async).with(waiting.id)
      expect(ProductionScriptRunWorker).not_to have_received(:perform_async).with(unapproved.id)
    end
  end

  describe ".run!" do
    def finishing(output, success)
      allow(Open3).to receive(:capture2e).and_return([output, instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 1)])
    end

    it "runs an approved script once and keeps what it printed" do
      script.update!(status: :approved)
      finishing("WROTE thing\n", true)

      described_class.run!(script)
      described_class.run!(script)

      expect(Open3).to have_received(:capture2e).once
      expect(script.reload).to be_status_succeeded
      expect(script.output).to eq("WROTE thing\n")
      expect(script.exit_status).to eq(0)
    end

    it "records a script that fails, with what it said" do
      script.update!(status: :approved)
      finishing("RuntimeError: nope\n", false)

      described_class.run!(script)

      expect(script.reload).to be_status_failed
      expect(script.output).to include("nope")
    end

    it "never runs one that isn't approved" do
      allow(Open3).to receive(:capture2e)

      described_class.run!(script)

      expect(Open3).not_to have_received(:capture2e)
      expect(script.reload).to be_status_pending
    end
  end

  describe "editing" do
    it "takes the approval away, whoever edits it" do
      script.update!(status: :approved, approved_at: Time.current)

      described_class.edit!(script, code: "puts 2", edited_by: :owner)

      expect(script.reload).to be_status_pending
      expect(script.approved_at).to be_nil
      expect(script.edited_by).to eq("owner")
    end

    it "leaves a skipped script skipped" do
      script.update!(status: :skipped)

      described_class.edit!(script, code: "puts 2", edited_by: :mini)

      expect(script.reload).to be_status_skipped
    end

    it "refuses a change while it's running" do
      script.update!(status: :running)

      expect { described_class.edit!(script, code: "puts 2", edited_by: :mini) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
