require "rails_helper"

# The byte service worker raises the "update ready" prompt when the shell it
# re-fetched carries a different `byte-version` from the one it had cached. That
# meta was COMMIT_SHA, so EVERY deploy asked for a hard reload — including one
# that only touched a Ruby service, where the open page is running exactly the
# code it should be. The kiosk had it worse: it hard-reloads itself on that
# signal, so the wall tablet restarted on every deploy.
RSpec.describe ByteShellVersion do
  before { described_class.reset! }
  after  { described_class.reset! }

  it "isn't the commit" do
    expect(described_class.current).not_to eq(COMMIT_SHA)
    expect(described_class.current).not_to eq(COMMIT_SHA[0, 12])
  end

  it "is stable across calls" do
    first = described_class.compute

    expect(described_class.compute).to eq(first)
  end

  it "is memoized, since nothing short of a deploy changes an input" do
    first = described_class.current
    allow(described_class).to receive(:compute).and_return("something-else")

    expect(described_class.current).to eq(first)
  end

  describe "what it's taken over" do
    # The three things that decide what the browser has in memory. Asserted on
    # `parts` rather than on the hash, so a passing test means the input is
    # really in there and not that some unrelated string moved.
    it "includes the fingerprinted bundles the page fetches" do
      expect(described_class.parts).to include(a_string_matching(%r{application.*\.js}))
    end

    it "includes the shell markup itself" do
      shell = Rails.root.join("app/views/byte/show.html.erb").read

      expect(described_class.parts).to include(shell)
    end

    it "includes the layout wrapped around it" do
      layout = Rails.root.join("app/views/layouts/application.html.erb").read

      expect(described_class.parts).to include(layout)
    end

    it "includes the service worker, which decides what gets served" do
      worker = Rails.public_path.join("byte_worker.js").read

      expect(described_class.parts).to include(worker)
    end
  end

  describe "moving" do
    it "changes when a bundle's fingerprint changes" do
      allow(described_class).to receive(:asset_fingerprint).and_return("/assets/application-aaa.js")
      before = described_class.compute
      allow(described_class).to receive(:asset_fingerprint).and_return("/assets/application-bbb.js")

      expect(described_class.compute).not_to eq(before)
    end

    it "changes when the shell markup changes" do
      real = described_class.parts
      before = described_class.compute
      allow(described_class).to receive(:parts).and_return(real + ["<div>new</div>"])

      expect(described_class.compute).not_to eq(before)
    end
  end

  # A version string is never worth a 500. Falling back to the commit restores
  # the old, noisy-but-correct behavior rather than freezing on a constant that
  # would never prompt at all.
  it "falls back to the commit rather than raising" do
    allow(described_class).to receive(:parts).and_raise(Errno::ENOENT)

    expect(described_class.compute).to eq(COMMIT_SHA)
  end

  # An asset the pipeline can't resolve shouldn't take the other inputs with it.
  it "survives an unresolvable asset" do
    allow(ActionController::Base.helpers).to receive(:asset_path).and_raise(StandardError)

    expect(described_class.compute).to be_present
    expect(described_class.compute).not_to eq(COMMIT_SHA)
  end
end
