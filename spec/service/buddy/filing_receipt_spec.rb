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

  it "replaces a reply that only reports the filing with the company and summary", :aggregate_failures do
    named  = call(:add_job_note, { "company" => "iCapital", "summary" => "iCapital confirmed Day 1 emails are coming." })
    opened = call(:add_job_application, { "company" => "Podium", "summary" => "Recruiter reached out about Staff AI Engineer." })

    [
      ["Set. It’s noted as their response on the iCapital row.", note, "iCapital: Disclosed the side business during onboarding."],
      # The summary alone when it already names the company.
      ["Done!", named, "iCapital confirmed Day 1 emails are coming."],
      ["Logged, it's on the board.", opened, "Podium: Recruiter reached out about Staff AI Engineer."],
    ].each do |body, filed, expected|
      expect(described_class.mend(body, [filed])).to eq(expected), body
    end
  end

  it "leaves a reply alone that says more, or when there is nothing to say instead", :aggregate_failures do
    bare = call(:add_job_note, { "company" => "iCapital", "tag" => "responded" })

    [
      ["iCapital says the PCIIA is standard and riders can't be attached.", note],
      # A booking that opens on the same word as a receipt.
      ["Set for Tuesday at 11:30am with RingCentral.", note],
      # The call wrote no summary.
      ["Done.", bare],
      # Nothing was filed.
      ["Done.", call(:log_event, { "name" => "Coffee" })],
    ].each do |body, filed|
      expect(described_class.mend(body, [filed])).to eq(body), body
    end
  end
end
