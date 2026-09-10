require "rails_helper"

# The line under an alert bubble. Open versus resolved is carried by the tint
# and the bar down the side, so this writes only what the bubble cannot show on
# its own — and nothing at all when there is nothing to add.
RSpec.describe "Byte alert status line" do
  let(:result) { JsRunner.output("spec/javascript/byte_alert_status_runner.js") }

  # A fixed string under every open alert is a line that appears every single
  # time the feature is used and never once says anything the reader didn't
  # already have from the colour. The colour reading as an ERROR was a colour
  # problem, and was fixed as one.
  it "says nothing under a condition seen once" do
    expect(result["open_once"]).to eq("state" => "open", "text" => "")
    expect(result["open_no_count"]).to eq("state" => "open", "text" => "")
  end

  # One bubble carries the condition across every occurrence, so without this
  # the second and third times it happened would be invisible.
  it "counts the recurrences and names when it was last seen" do
    expect(result["open_repeated"]["text"]).to eq("Seen 3× · last 5:04 PM")
  end

  # The bubble's own timestamp is when the thing was first NOTICED. The two are
  # often days apart, so the clearing time is not something it already says.
  it "names when it cleared" do
    expect(result["resolved"]).to eq("state" => "resolved", "text" => "Resolved 5:04 PM")
  end

  # Nobody checked the condition - the person said stop asking. Calling that
  # "resolved" would be a record of something that never happened.
  it "never calls a dismissal a resolution" do
    expect(result["dismissed"]["text"]).to eq("Let go 5:04 PM")
    expect(result["dismissed"]["text"]).not_to match(/resolv/i)
    # It still RECEDES like a resolution - it is done being asked about.
    expect(result["dismissed"]["state"]).to eq("resolved")
  end

  it "drops the clock rather than the sentence when there's no time to show" do
    expect(result["open_repeated_no_clock"]["text"]).to eq("Seen 3×")
    expect(result["resolved_no_clock"]["text"]).to eq("Resolved")
  end

  it "has no opinion about a message that isn't an alert" do
    expect(result["missing"]).to be_nil
    expect(result["not_an_alert"]).to be_nil
  end

  # It comes off jsonb, and jsonb has handed over a string before now.
  it "reads a count that arrived as text" do
    expect(result["count_as_string"]["text"]).to eq("Seen 4×")
  end

  # An alert keeps ONE bubble for as long as it is open, which is what stops a
  # standing condition turning into a run of identical notifications - and is
  # also its one weakness: a thread moves on, and a bubble raised on Tuesday is
  # a hundred messages up by Thursday. The strip is pinned so an outstanding
  # thing cannot be lost by being scrolled past.
  describe "the pinned strip" do
    let(:row) { result["row"] }

    it "carries the caller's own sentence" do
      expect(row["once"]).to eq("The gate is open")
      expect(row["no_count"]).to eq("The gate is open")
    end

    it "reports the recurrences where there are any" do
      expect(row["repeated"]).to eq("The gate is open (×4)")
    end

    it "answers with something for a row carrying nothing" do
      expect(row["blank"]).to eq("")
      expect(row["nothing"]).to eq("")
    end

    # Scrolling a strip pinned over the pet put a full-height native scrollbar
    # down his side — worse than the problem, and over a list nobody wants to
    # scroll. Two are drawn and the rest are a count.
    describe "when several are outstanding at once" do
      let(:overflow) { result["overflow"] }

      it "draws at most two and counts the rest" do
        expect(overflow["max_rows"]).to eq(2)
        expect(overflow["one_over"]).to eq("+1 more outstanding")
        expect(overflow["many"]).to eq("+7 more outstanding")
      end

      it "says nothing while they all fit" do
        expect(overflow["zero"]).to be_nil
        expect(overflow["none"]).to be_nil
        expect(overflow["exactly_full"]).to be_nil
      end
    end
  end

  # The label is only half of it. The other half is three files agreeing that
  # `alert` is a kind at all, and each of them fails quietly on its own: a
  # bubble with no place to put the line, a kind that falls through to plain
  # text, or a state class nothing paints.
  describe "the wiring behind it" do
    let(:index) { Rails.root.join("app/javascript/src/pages/byte/index.js").read }

    it "has somewhere to put the line" do
      expect(Rails.root.join("app/views/byte/show.html.erb").read).to include("data-alert")
      expect(index).to include('node.querySelector("[data-alert]")')
    end

    it "renders an alert body as markdown rather than falling through to plain text" do
      expect(index).to include('kind === "alert"')
    end

    it "paints both states" do
      css = Rails.root.join("app/assets/stylesheets/pages/byte.scss").read

      expect(index).to include("byte-msg-alert-open", "byte-msg-alert-resolved")
      expect(css).to include("&.byte-msg-alert-open", "&.byte-msg-alert-resolved")
    end

    it "pins the strip where it cannot be scrolled past" do
      expect(Rails.root.join("app/views/byte/show.html.erb").read).to include("data-byte-alert-bar")
      expect(index).to include("initAlertStrip")
      expect(index).to include('data.kind === "alerts"')
    end

    # In flow it took its height off `.byte-buddy-char`, which is `flex: 1` in a
    # capped hero — so every open alert made the character smaller.
    it "overlays the hero instead of taking its height off the character" do
      css = Rails.root.join("app/assets/stylesheets/pages/byte.scss").read
      bar = css[/\.byte-alert-bar \{(.*?)\n\}/m, 1].to_s

      expect(bar).to include("position: absolute")
      expect(bar).not_to include("overflow-y: auto")
    end

    # `update: true` is what stops a rewritten bubble reading as a new message:
    # no unread count, no notice, no push. Without it, resolving would announce
    # itself as though something had just arrived.
    it "repaints in place instead of announcing itself" do
      alerts = Rails.root.join("app/service/buddy/alerts.rb").read

      expect(alerts).to include("update: true")
      expect(index).to include("if (data.update) {")
    end
  end
end
