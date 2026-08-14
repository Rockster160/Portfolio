require "rails_helper"

# A message carrying icons reaches surfaces that have no pixels to give them —
# a push notification most of all. Sent as written, "Rocco: [hicon:24]
# [hicon:22]" arrives as its own source code.
RSpec.describe IconPool, ".refs_to_text" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:icon) {
    household.icons.create!(
      name: "Fae", uploaded_by_user: user,
      image_data: "data:image/png;base64,iVBORw0KGgo="
    )
  }

  before { user.update!(chore_household_id: household.id) }

  it "names an icon written by id" do
    expect(described_class.refs_to_text("feeding [hicon:#{icon.id}] now", user: user))
      .to eq("feeding Fae now")
  end

  # Prod: this arrived typed with a space in it.
  it "names one written with a space after the colon" do
    expect(described_class.refs_to_text("feeding [hicon: #{icon.id}] now", user: user))
      .to eq("feeding Fae now")
  end

  it "keeps a name written as a name" do
    expect(described_class.refs_to_text("feeding [hicon fae] now", user: user))
      .to eq("feeding Fae now")
  end

  it "names a Tabler icon" do
    expect(described_class.refs_to_text("[ticon:ti-fa-fire]", user: user)).to be_present
    expect(described_class.refs_to_text("[ticon:ti-fa-fire]", user: user)).not_to include("[")
  end

  it "handles a run of them" do
    text = described_class.refs_to_text("[hicon:#{icon.id}] [hicon:#{icon.id}]", user: user)

    expect(text).to eq("Fae Fae")
  end

  # An icon from another household, or one since deleted. A stray word beats a
  # stray `[hicon:999]`.
  it "falls back to the written text when nothing resolves" do
    expect(described_class.refs_to_text("[hicon:999999]", user: user)).to eq("")
    expect(described_class.refs_to_text("[hicon Nonesuch]", user: user)).to eq("Nonesuch")
  end

  it "refuses an icon from a household this person isn't in" do
    outsider = create(:user)
    other = ChoreHousehold.create!(name: "Elsewhere", owner_user: outsider)
    theirs = other.icons.create!(
      name: "Secret", uploaded_by_user: outsider,
      image_data: "data:image/png;base64,iVBORw0KGgo="
    )

    expect(described_class.refs_to_text("[hicon:#{theirs.id}]", user: user)).to eq("")
  end

  it "leaves text with no references exactly as it was" do
    expect(described_class.refs_to_text("just words", user: user)).to eq("just words")
  end

  it "survives no user at all" do
    expect(described_class.refs_to_text("[hicon Fae] there", user: nil)).to eq("Fae there")
  end
end
