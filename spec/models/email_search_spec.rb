require "rails_helper"

# The email list's search box. Every term has to narrow to the right rows - and
# a term that matched everything, like `in:all`, used to come back as zero rows
# because an empty WHERE read as "nothing could be made of it".
RSpec.describe Email do
  let(:user) { create(:user) }
  let!(:order) { email!(subject: "Your order shipped", name: "Amazon", tags: ["Receipts"]) }
  let!(:read_mail) { email!(subject: "Old news", theirs: "news@paper.com", read_at: 1.hour.ago) }
  let!(:archived) { email!(subject: "Archived thing", theirs: "x@y.com", archived_at: 1.hour.ago) }
  let!(:sent) {
    email!(subject: "Hi Billy", direction: :outbound, ours: "rocco@rdjn.com", theirs: "billy@bob.com")
  }
  let!(:attached) { email!(subject: "Invoice", theirs: "billing@acme.io", has_attachments: true, at: 10.days.ago) }
  let!(:someone_elses) { email!(subject: "Your order shipped", user: other_user) }
  let(:other_user) { create(:user) }

  def email!(
    subject:,
    direction: :inbound,
    ours: "rocco@rdjn.com",
    theirs: "orders@amazon.com",
    name: nil,
    at: 1.day.ago,
    **attrs)
    described_class.create!(
      user:               attrs.delete(:user) || user,
      mail_id:            "es-#{SecureRandom.hex(4)}",
      timestamp:          at,
      direction:          direction,
      inbound_mailboxes:  [{ name: nil, address: ours }],
      outbound_mailboxes: [{ name: name, address: theirs }],
      subject:            subject,
      blurb:              "Some words.",
      **attrs,
    )
  end

  def search(q) = user.emails.query(q)

  it "is the inbox when blank" do
    expect(search("")).to contain_exactly(order, read_mail, attached)
  end

  it "reaches every email of theirs with in:all, and nobody else's" do
    expect(search("in:all")).to contain_exactly(order, read_mail, archived, sent, attached)
  end

  it "keeps the caller's scope rather than searching every user" do
    expect(search("order")).not_to include(someone_elses)
  end

  it "searches the sender by address, domain, and name" do
    expect(search("from:orders@amazon.com")).to contain_exactly(order)
    expect(search("from:amazon.com")).to contain_exactly(order)
    expect(search("from:Amazon")).to contain_exactly(order)
  end

  it "reads to: and from: by direction" do
    expect(search("to:rocco@rdjn.com")).to contain_exactly(order, read_mail, attached)
    expect(search("from:rocco@rdjn.com")).to contain_exactly(sent)
    expect(search("to:billy@bob.com")).to contain_exactly(sent)
  end

  it "finds a bare address on either side" do
    expect(search("billy@bob.com")).to contain_exactly(sent)
    expect(search("billy@bob.com subject:billy")).to contain_exactly(sent)
  end

  it "searches subject" do
    expect(search("subject:shipped")).to contain_exactly(order)
  end

  it "searches tags, case-insensitively, and negated" do
    expect(search("tag:receipts")).to contain_exactly(order)
    expect(search("-tag:receipts")).to contain_exactly(read_mail, attached)
    expect(search("is:untagged")).to contain_exactly(read_mail, attached)
  end

  it "searches state" do
    expect(search("is:read")).to contain_exactly(read_mail)
    expect(search("is:unread")).to contain_exactly(order, attached)
    expect(search("is:archived")).to contain_exactly(archived)
    expect(search("in:sent")).to contain_exactly(sent)
    expect(search("has:attachment")).to contain_exactly(attached)
  end

  it "searches timestamps" do
    cutoff = 5.days.ago.to_date.iso8601
    expect(search("before:#{cutoff}")).to contain_exactly(attached)
    expect(search("after:#{cutoff}")).to contain_exactly(order, read_mail)
    expect(search("timestamp<#{cutoff}")).to contain_exactly(attached)
  end

  it "combines terms with OR" do
    expect(search("tag:receipts OR has:attachment")).to contain_exactly(order, attached)
  end

  it "says so when a date cannot be read" do
    expect(search("after:notadate")).to be_empty
    expect(described_class.search_notes.join).to include("notadate")
  end
end
