require "rails_helper"

# A job-mail notification reading "Done." is replaced by the line the filing
# call wrote. See Buddy::FilingReceipt.
RSpec.describe Buddy::FilingReceipt do
  def call(name, arguments)
    { name: name, arguments: arguments }
  end

  let(:note) {
    call(:add_job_note, { "company" => "iCapital", "summary" => "Disclosed the side business during onboarding." })
  }

  describe "a reply that only reports the filing" do
    it "becomes the company and the summary" do
      out = described_class.mend("Set. It’s noted as their response on the iCapital row.", [note])

      expect(out).to eq("iCapital: Disclosed the side business during onboarding.")
    end

    it "takes the summary alone when it already names the company" do
      named = call(:add_job_note, { "company" => "iCapital", "summary" => "iCapital confirmed Day 1 emails are coming." })

      expect(described_class.mend("Done!", [named])).to eq("iCapital confirmed Day 1 emails are coming.")
    end

    it "reads a new company's row the same way" do
      opened = call(:add_job_application, { "company" => "Podium", "summary" => "Recruiter reached out about Staff AI Engineer." })

      expect(described_class.mend("Logged, it's on the board.", [opened])).to eq(
        "Podium: Recruiter reached out about Staff AI Engineer.",
      )
    end
  end

  describe "what it leaves alone" do
    it "keeps a sentence about the mail" do
      body = "iCapital says the PCIIA is standard and riders can't be attached."

      expect(described_class.mend(body, [note])).to eq(body)
    end

    it "keeps a booking that opens on the same word" do
      body = "Set for Tuesday at 11:30am with RingCentral."

      expect(described_class.mend(body, [note])).to eq(body)
    end

    it "keeps the receipt when the call wrote no summary" do
      bare = call(:add_job_note, { "company" => "iCapital", "tag" => "responded" })

      expect(described_class.mend("Done.", [bare])).to eq("Done.")
    end

    it "keeps the receipt when nothing was filed" do
      expect(described_class.mend("Done.", [call(:log_event, { "name" => "Coffee" })])).to eq("Done.")
    end
  end
end
