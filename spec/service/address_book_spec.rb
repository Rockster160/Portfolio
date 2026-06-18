require "rails_helper"

# Locks in the natural-language contact-name normalization used by
# Tesla.navigate, Jarvis voice, and any other caller that needs to resolve
# "Sarah", "Sarah's", "Sarah's house", "Sarahs" to the same Sarah contact.
RSpec.describe AddressBook do
  describe ".name_variants" do
    {
      "Sarah"           => %w[Sarah],
      "Sarah's"         => ["Sarah's", "Sarah"],
      "Sarah’s"         => ["Sarah’s", "Sarah"],            # curly apostrophe
      "Sarah's house"   => ["Sarah's house", "Sarah"],
      "Sarah's home"    => ["Sarah's home", "Sarah"],
      "Sarah's place"   => ["Sarah's place", "Sarah"],
      "Sarah’s house"   => ["Sarah’s house", "Sarah"],
      "Sarahs"          => %w[Sarahs Sarah],
    }.each do |input, expected|
      it "expands #{input.inspect} to #{expected.inspect}" do
        expect(described_class.name_variants(input)).to eq(expected)
      end
    end

    it "returns [] for blank input" do
      expect(described_class.name_variants("")).to eq([])
      expect(described_class.name_variants("   ")).to eq([])
    end
  end

  describe "#to_traveltime_param" do
    let(:book) { described_class.new(User.me) }

    it "resolves contact-name strings (Home, Sarah, etc.) to their street address" do
      home = double(primary_address: double(street: "123 Main St", present?: true))
      allow(book).to receive(:match_contact).with("Home").and_return(home)
      expect(book).not_to receive(:reverse_geocode)
      expect(book.to_traveltime_param("Home")).to eq("123 Main St")
    end

    it "passes raw address strings through stripped when no contact matches" do
      allow(book).to receive(:match_contact).and_return(nil)
      expect(book).not_to receive(:reverse_geocode)
      expect(book.to_traveltime_param("  1 Apple Park Way  ")).to eq("1 Apple Park Way")
    end

    it "joins coordinate arrays directly (no reverse_geocode)" do
      expect(book).not_to receive(:reverse_geocode)
      expect(book.to_traveltime_param([40.4804, -111.998])).to eq("40.4804,-111.998")
    end

    it "delegates non-string/non-coord input to to_address" do
      contact = double("Contact")
      expect(book).to receive(:to_address).with(contact).and_return("Resolved Address")
      expect(book.to_traveltime_param(contact)).to eq("Resolved Address")
    end

    it "returns nil for blank input" do
      expect(book.to_traveltime_param("   ")).to be_nil
    end
  end

  describe "#traveltime_seconds" do
    let(:book) { described_class.new(User.me) }

    def stub_response(duration_in_traffic: nil, duration: nil)
      element = {}
      element[:duration_in_traffic] = { value: duration_in_traffic } if duration_in_traffic
      element[:duration] = { value: duration } if duration
      double(body: { rows: [{ elements: [element] }] }.to_json)
    end

    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(book).to receive(:to_traveltime_param) { |x| x }
      allow(book).to receive(:current_loc).and_return("origin")
    end

    it "returns 0 and skips the API call when origin == destination" do
      expect(RestClient).not_to receive(:get)
      expect(book.traveltime_seconds("Home", "Home")).to eq(0)
    end

    it "sends departure_time=now + traffic_model and reads duration_in_traffic" do
      captured_url = nil
      allow(RestClient).to receive(:get) { |url|
        captured_url = url
        stub_response(duration_in_traffic: 2700, duration: 2100)
      }

      expect(book.traveltime_seconds("dest", "origin")).to eq(2700)
      expect(captured_url).to include("traffic_model=best_guess")
      expect(captured_url).to include("departure_time=now")
      expect(captured_url).not_to include("arrival_time=")
    end

    it "passes a future arrival timestamp as departure_time" do
      future = 1.hour.from_now.to_i
      captured_url = nil
      allow(RestClient).to receive(:get) { |url|
        captured_url = url
        stub_response(duration_in_traffic: 1800)
      }

      book.traveltime_seconds("dest", "origin", at: future)
      expect(captured_url).to include("departure_time=#{future}")
    end

    it "falls back to plain duration when duration_in_traffic is missing" do
      allow(RestClient).to receive(:get).and_return(stub_response(duration: 1500))
      expect(book.traveltime_seconds("dest", "origin")).to eq(1500)
    end

    it "re-queries Google after the 10-minute cache bucket rolls over" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)

      allow(RestClient).to receive(:get).and_return(
        stub_response(duration_in_traffic: 1800),
        stub_response(duration_in_traffic: 2700),
      )

      t = Time.current
      travel_to(t) do
        expect(book.traveltime_seconds("dest", "origin")).to eq(1800)
      end
      travel_to(t + 2.minutes) do
        # Same bucket — cache hit, no new fetch
        expect(book.traveltime_seconds("dest", "origin")).to eq(1800)
      end
      travel_to(t + 11.minutes) do
        # Next bucket — re-fetches and gets the fresher number
        expect(book.traveltime_seconds("dest", "origin")).to eq(2700)
      end

      expect(RestClient).to have_received(:get).twice
    end
  end

  describe "#match_contact" do
    let(:book)  { described_class.new(User.me) }
    let(:sarah) { instance_double("Contact", present?: true) }

    before do
      # contact_by_name returns sarah only for the bare "Sarah".
      allow(book).to receive(:contact_by_name).and_return(nil)
      allow(book).to receive(:contact_by_name).with("Sarah").and_return(sarah)
    end

    it "returns the contact when the original string matches" do
      expect(book.match_contact("Sarah")).to eq(sarah)
    end

    it "tries normalized variants and returns the first hit" do
      expect(book.match_contact("Sarah's house")).to eq(sarah)
      expect(book.match_contact("Sarahs")).to eq(sarah)
    end

    it "returns nil when nothing matches any variant" do
      expect(book.match_contact("Unknown Person")).to be_nil
    end
  end
end
