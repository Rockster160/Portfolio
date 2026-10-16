require "rails_helper"

RSpec.describe Jil::ListenerMatch do
  def hit?(listener, data, scope: :travel)
    described_class.call(listener, scope, data)
  end

  let(:home) { { action: "departed", departed: "Home", lat: 40.4805, lng: -111.9982 } }
  let(:work) { { action: "departed", departed: "Work", lat: 40.53, lng: -112.01 } }

  # The tokenizer reads a leading `-` per value ("some value isn't this one"),
  # which made `-departed::Home` fire on Home and nowhere else.
  describe "excluding a term" do
    it "matches only events the term does not, however it's written" do
      ["-departed::Home", "!departed::Home", "NOT departed::Home"].each { |term|
        expect(hit?("travel:action::departed #{term}", home)).to be(false), term
        expect(hit?("travel:action::departed #{term}", work)).to be(true), term
      }
    end

    it "excludes trivially when the payload doesn't carry the key" do
      expect(hit?("travel:action::departed -departed::Home", { action: "departed" })).to be(true)
    end

    it "excludes a regex or a nested path the same way" do
      item = { action: "added", list: { name: "Groceries" } }

      expect(hit?("item:action::added -list:name:/^groc/", item, scope: :item)).to be(false)
      expect(hit?("item:action::added -list:name::Claude", item, scope: :item)).to be(true)
    end
  end

  describe "near()" do
    it "matches a payload's coordinates within the radius" do
      expect(hit?("travel:action::departed near(40.4805 -111.9982)", home)).to be(true)
      expect(hit?("travel:action::departed near(40.4805 -111.9982)", work)).to be(false)
      expect(hit?("travel:action::departed near(40.4805, -111.9982, 10km)", work)).to be(true)
    end

    it "excludes like any other term" do
      expect(hit?("travel:action::departed -near(40.4805 -111.9982 550m)", home)).to be(false)
      expect(hit?("travel:action::departed -near(40.4805 -111.9982 550m)", work)).to be(true)
    end

    it "reads under a key path" do
      parked = { tesla: { lat: 40.4805, lng: -111.9982 } }

      expect(hit?("tesla_parked tesla:near(40.4805 -111.9982)", parked, scope: :tesla_parked)).to be(true)
    end

    # "Can't tell" is not "somewhere else": a payload with no coordinates
    # matches neither the place nor its exclusion.
    it "never matches without coordinates" do
      bare = { action: "departed", location: "Home" }

      expect(hit?("travel:action::departed near(40.4805 -111.9982)", bare)).to be(false)
      expect(hit?("travel:action::departed -near(40.4805 -111.9982)", bare)).to be(false)
    end

    it "is refused when its arguments could never work" do
      expect(described_class.fault("travel near(home)")).to include("needs a latitude")
      expect(described_class.fault("travel near(40.4 -111.9 far)")).to include("needs a latitude")
      expect(described_class.fault("travel near(40.4 -111.9 200m)")).to be_nil
    end
  end

  it "reads the scope off a listener that starts with a bare one" do
    expect(described_class.scope_of("travel action::arrived")).to eq("travel")
    expect(described_class.scope_of("item:list:name::Claude")).to eq("item")
  end
end
