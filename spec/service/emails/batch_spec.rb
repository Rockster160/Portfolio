require "rails_helper"

RSpec.describe Emails::Batch do
  let(:user) { create(:user) }
  let!(:fresh) { email! }
  let!(:done) { email!(read_at: 1.hour.ago, archived_at: 1.hour.ago, tags: ["Travel"]) }
  let(:scope) { Email.where(user: user) }

  def email!(**attrs)
    Email.create!(
      user:               user,
      mail_id:            "eb-#{SecureRandom.hex(4)}",
      timestamp:          1.day.ago,
      direction:          :inbound,
      inbound_mailboxes:  [{ address: "rocco@rdjn.com" }],
      outbound_mailboxes: [{ address: "a@b.com" }],
      subject:            "Hello",
      blurb:              "",
      **attrs,
    )
  end

  it "archives and unarchives, counting only what changed" do
    expect(described_class.call(scope, :archive)).to eq(1)
    expect(fresh.reload).to be_archived
    expect(described_class.call(scope, :unarchive)).to eq(2)
    expect(scope.archived).to be_empty
  end

  it "marks read and unread" do
    expect(described_class.call(scope, "read")).to eq(1)
    expect(fresh.reload).to be_read
    expect(described_class.call(scope, "unread")).to eq(2)
    expect(scope.read).to be_empty
  end

  it "adds tags without doubling one already there in another case" do
    expect(described_class.call(scope, :add_tags, tags: "travel, Receipts")).to eq(2)
    expect(fresh.reload.tags).to eq(["travel", "Receipts"])
    expect(done.reload.tags).to eq(["Travel", "Receipts"])
  end

  it "removes tags case-insensitively" do
    expect(described_class.call(scope, :remove_tags, tags: "TRAVEL")).to eq(1)
    expect(done.reload.tags).to eq([])
  end

  it "refuses an operation it does not know" do
    expect { described_class.call(scope, :destroy) }.to raise_error(described_class::UnknownOperation)
  end
end
