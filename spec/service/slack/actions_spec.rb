require "rails_helper"

RSpec.describe Slack::Actions do
  around { |example|
    kept = described_class.registry.dup
    example.run
    described_class.registry.replace(kept)
  }

  it "runs the handler and hands back what it said" do
    described_class.register(:spec_thing, label: "Do it", run: ->(params) { "did it: #{params[:with]}" })

    expect(described_class.call(:spec_thing, { with: "a hammer" })).to eq([:ok, "did it: a hammer"])
  end

  # A link outlives the feature it was posted for. Somebody tapping a month-old
  # message should be told that, not shown a 500.
  it "answers a name it no longer knows without raising" do
    status, said = described_class.call(:long_gone)

    expect(status).to eq(:unknown)
    expect(said).to include("isn't a thing")
  end

  it "reports a handler that blew up rather than letting it escape" do
    described_class.register(:spec_boom, label: "Boom", run: ->(_p) { raise "kaboom" })

    status, said = described_class.call(:spec_boom)

    expect(status).to eq(:error)
    expect(said).to include("kaboom")
  end

  describe ".link" do
    it "is Slack's own link syntax, labelled from the registration" do
      described_class.register(:spec_thing, label: "🔄 Do it", run: ->(_p) { "ok" })

      expect(described_class.link(:spec_thing)).to end_with("/slack/action/spec_thing|🔄 Do it>")
    end

    it "carries params through" do
      described_class.register(:spec_thing, label: "Do it", run: ->(_p) { "ok" })

      expect(described_class.link(:spec_thing, id: 7)).to include("/slack/action/spec_thing?id=7|")
    end
  end

  it "has the buddy retry registered at boot" do
    expect(described_class.find(:buddy_retry)).to be_present
  end
end
