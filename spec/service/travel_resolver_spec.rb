require "rails_helper"

# One leg, one row, however many things saw it. The reporters disagree about
# vocabulary ("depart" / "departed" / "left"), about coordinate shape (a pair,
# two keys, or the `"lat,lng"` string the offline queue tokenizes out of a
# Shortcut line), and about timing — a phone geofence trips at its radius and
# the car when it rolls, minutes apart on the same journey.
RSpec.describe TravelResolver do
  let(:user) { create(:user) }
  let(:home) { [40.48038, -111.99827] }

  before { allow(::LocationCache).to receive(:current_location_name).and_return("Home") }

  def record(**payload)
    described_class.record({ action: :departed, lat: home.first, lng: home.last }.merge(payload), user: user)
  end

  describe "the words each reporter uses" do
    it "reads them all as the same two things" do
      words = {
        depart:   :departed,
        departed: :departed,
        left:     :departed,
        exit:     :departed,
        arrive:   :arrived,
        arrived:  :arrived,
        enter:    :arrived,
      }

      expect(words.transform_values { |_| nil }.keys.index_with { |word|
        described_class.normalize_action(word)
      }).to eq(words)
    end

    it "is not case or whitespace sensitive" do
      expect(described_class.normalize_action(" Arrived ")).to eq(:arrived)
    end

    it "records nothing for a word it doesn't know" do
      expect(record(action: :loitering)).to be_nil
    end
  end

  describe "the coordinate" do
    it "takes separate lat and lng keys" do
      expect(described_class.coord_from(lat: 40.1, lng: -111.9)).to eq([40.1, -111.9])
    end

    it "takes a pair" do
      expect(described_class.coord_from(coord: [40.1, -111.9])).to eq([40.1, -111.9])
    end

    # What `Tokenizing.parse` pulls out of `location:"40.48,-111.99"`.
    it "takes the offline queue's string" do
      expect(described_class.coord_from(location: "40.48045593063188,-111.9983115258447"))
        .to eq([40.48045593063188, -111.9983115258447])
    end

    it "has none when the location is a place name" do
      expect(described_class.coord_from(location: "Home")).to be_nil
    end
  end

  describe "recording a leg" do
    it "opens a row named for what happened" do
      result = record(source: :phone)

      event = ActionEvent.find(result[:event_id])
      expect(event.name).to eq("departed")
      expect(event.notes).to eq("Home")
    end

    # How a report reached us decides whether to believe it; it is not a fact
    # about the leg, and it does not go on the row.
    it "files the reporter's coordinate under the reporter's own key, and nothing else" do
      result = record(source: :phone)

      expect(ActionEvent.find(result[:event_id]).data).to eq(
        "phone" => { "lat" => home.first, "lng" => home.last, "name" => "Home" },
      )
    end

    it "adds a second reporter to the same row" do
      first = record(source: :phone)
      second = record(source: :tesla, lat: 40.480359, lng: -111.998125)

      expect(second[:event_id]).to eq(first[:event_id])
      expect(ActionEvent.find(first[:event_id]).data.keys).to contain_exactly("phone", "tesla")
    end

    it "opens a new row once the window has passed" do
      first = record(source: :phone)

      second = travel_to((described_class::MERGE_WINDOW + 1.minute).from_now) { record(source: :tesla) }

      expect(second[:event_id]).not_to eq(first[:event_id])
    end

    it "keeps departures and arrivals apart" do
      departed = record(action: :departed, source: :phone)
      arrived = record(action: :arrived, source: :phone)

      expect(arrived[:event_id]).not_to eq(departed[:event_id])
    end

    # The car's reverse-geocode is the coarser of the two names, and `notes` is
    # what a person reads off the event.
    it "lets the phone name the place, not the car" do
      allow(::LocationCache).to receive(:current_location_name).and_return("Herriman")
      first = record(source: :tesla)
      allow(::LocationCache).to receive(:current_location_name).and_return("Home")

      record(source: :phone)

      expect(ActionEvent.find(first[:event_id]).notes).to eq("Home")
    end
  end

  describe "who is allowed to announce it" do
    it "lets the phone, which is where the person is" do
      expect(record(source: :phone)[:announce]).to be(true)
    end

    # Everything listening on `travel:` — the garage verify, the TODO ping, the
    # queued arrival commands — is about Rocco being gone, not the car.
    it "does not let the car" do
      expect(record(source: :tesla)[:announce]).to be(false)
    end

    # The car crosses the home boundary before a geofence at its radius does,
    # so on any drive the car opens the row and the phone arrives second.
    # Announcing on row creation would hand every leg to the one reporter that
    # must never announce.
    it "still lets the phone announce a leg the car opened" do
      record(source: :tesla)

      expect(record(source: :phone)[:announce]).to be(true)
    end

    it "announces the leg once, not once per phone report" do
      record(source: :phone)

      expect(record(source: :phone)[:announce]).to be(false)
    end

    it "defaults an unnamed reporter to the phone" do
      expect(record[:source]).to eq(:phone)
    end
  end

  # 2026-09-10: the radio connected and dropped five times in three minutes
  # from the same spot in the garage while Rocco was inside the house, and the
  # first of those recorded a departure that stood unmatched all day.
  describe "a Bluetooth pairing in the garage" do
    let(:garage) { [40.480456, -111.998311] }

    before do
      allow(::LocationCache).to receive(:at_home?) { |coord| coord.present? && coord.first > 40.48 && coord.first < 40.481 }
    end

    def pairing(**payload)
      described_class.record(
        { action: :depart, lat: garage.first, lng: garage.last, via: :bluetooth }.merge(payload), user: user
      )
    end

    it "records nothing at all" do
      expect { pairing }.not_to change(ActionEvent, :count)
    end

    it "reports having recorded nothing" do
      expect(pairing).to be_nil
    end

    it "stays quiet through the whole storm" do
      expect {
        5.times { pairing(action: :depart) && pairing(action: :arrive) }
      }.not_to change(ActionEvent, :count)
    end

    # The live post says `bluetooth_connected` outright and is labelled in
    # Ruby. The copy the Shortcut replays carries only the coordinate, so its
    # own vocabulary is the only marker it has: 80 of 81 `depart` lines and 74
    # of 75 `arrive` lines in the log window arrived alongside a Bluetooth
    # post, against 10 of 59 `arrived` lines.
    it "knows the queued copy by the word the automation uses" do
      expect(described_class.normalize_via(action: "depart")).to eq(:bluetooth)
      expect(described_class.normalize_via(action: "arrive")).to eq(:bluetooth)
    end

    # The half-word that separates the two automations. A geofence departure
    # has never arrived in five weeks; this is what will honour the first one
    # that does, with nothing added to the Shortcut.
    it "believes the geofence's own vocabulary" do
      expect(described_class.normalize_via(action: "arrived")).to eq(:geofence)
      expect(described_class.normalize_via(action: "departed")).to eq(:geofence)
    end

    it "takes an explicit label over the word" do
      expect(described_class.normalize_via(action: "depart", via: "geofence")).to eq(:geofence)
      expect(described_class.normalize_via(action: "departed", via: "bluetooth")).to eq(:bluetooth)
    end

    it "refuses the queued copy at home, by its word alone" do
      expect { pairing(action: :depart, via: nil) }.not_to change(ActionEvent, :count)
    end

    # Which is the whole point of keeping the distinction: the geofence
    # reporting from the same spot is the signal, not the noise.
    it "does not refuse a geofence departure from the same spot" do
      expect { pairing(action: :departed, via: nil) }.to change(ActionEvent, :count).by(1)
    end

    # The geofence is what the house is meant to listen to at home, and it
    # trips at its own radius — sometimes right on the pin.
    it "does not swallow the geofence reporting from the same spot" do
      expect { pairing(action: :departed, via: :geofence) }.to change(ActionEvent, :count).by(1)
    end

    # The pairing that matters: connect at Home, drop at Horsetail Falls.
    it "does not swallow the same radio away from home" do
      expect { pairing(action: :arrive, lat: 40.48263, lng: -111.75021) }.to change(ActionEvent, :count).by(1)
    end
  end

  # Chelsea taking the car while Rocco stays in: a `departed` row that carries
  # the car and nothing else. This is the query that answers it.
  it "leaves the car's solo legs findable and silent" do
    record(source: :tesla)

    solo = user.action_events.where(name: :departed).search_data_source(:tesla).reject { |e|
      e.data.key?("phone")
    }
    expect(solo.length).to eq(1)
  end
end
