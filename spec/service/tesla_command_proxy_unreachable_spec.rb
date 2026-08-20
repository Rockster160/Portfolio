require "rails_helper"

# The dashboard Tesla cell renders straight off this broadcast, so the flag and
# the broadcast have to move together. They didn't: the clear path wrote the
# flag and left the push to whatever broadcast happened next, which inside a
# command is fine and outside one never comes.
RSpec.describe TeslaCommand, ".proxy_unreachable!" do
  before do
    DataStorage.where(name: :tesla_proxy_unreachable).delete_all
    allow(described_class).to receive(:broadcast)
  end

  it "sets the flag and pushes it to the dashboard" do
    described_class.proxy_unreachable!(true)

    expect(DataStorage[:tesla_proxy_unreachable]).to be(true)
    expect(described_class).to have_received(:broadcast).with({})
  end

  it "clears the flag and pushes that too — the case the dashboard was missing" do
    DataStorage[:tesla_proxy_unreachable] = true

    described_class.proxy_unreachable!(false)

    expect(DataStorage[:tesla_proxy_unreachable]).to be(false)
    expect(described_class).to have_received(:broadcast).with({})
  end

  # The clear path runs after EVERY successful command, so a no-op has to stay
  # a no-op: no row churn and no redundant redraw.
  it "does nothing at all when the value is unchanged" do
    DataStorage[:tesla_proxy_unreachable] = false

    expect { described_class.proxy_unreachable!(false) }.not_to(change { DataStorage.find_by(name: :tesla_proxy_unreachable).updated_at })
    expect(described_class).not_to have_received(:broadcast)
  end

  # Setting it twice still has to broadcast, because `loading: false` is what
  # stops the dashboard spinner and that has to go out regardless.
  it "still broadcasts an unchanged value when extra data rides along" do
    DataStorage[:tesla_proxy_unreachable] = true

    described_class.proxy_unreachable!(true, loading: false)

    expect(described_class).to have_received(:broadcast).with({ loading: false })
  end

  it "coerces truthy input so the stored flag is always a real boolean" do
    described_class.proxy_unreachable!("yes")

    expect(DataStorage[:tesla_proxy_unreachable]).to be(true)
  end
end
