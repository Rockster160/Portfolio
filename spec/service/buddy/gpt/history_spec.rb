require "rails_helper"

RSpec.describe Buddy::GPT::History do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  def said(body, direction: :outbound, kind: nil, state: :delivered, source: nil, peer: nil)
    meta = {}
    meta["kind"]        = kind if kind
    meta["source"]      = source if source
    meta["relay_peer"]  = { "name" => peer } if peer
    convo.byte_messages.create!(
      user: user, direction: direction, state: state, body: body, metadata: meta,
    )
  end

  def build(upto: nil)
    described_class.build(convo, upto: upto)
  end

  describe "roles" do
    it "maps the person's messages to user and Buddy's replies to assistant" do
      said("morning")
      said("Morning!", direction: :inbound, kind: "buddy")

      expect(build).to eq([
        { role: :user, content: "morning" },
        { role: :assistant, content: "Morning!" },
      ])
    end

    it "includes hidden seed prompts, which are how Buddy gets told to speak up" do
      said("[scheduled prompt] Rocco just added an event, give her a heads-up", kind: "buddy_trigger")

      expect(build.first[:role]).to eq(:user)
      expect(build.first[:content]).to include("just added an event")
    end
  end

  # Tapping a quick action posts a wall of instructions as the person's turn.
  # It's hidden in the UI but replayed in full forever, and it's IDENTICAL every
  # time - one prod thread carried NINE Today seeds in a single day, ~40k
  # characters of the same prompt, each followed by that day's briefing.
  #
  # That's a few-shot example set, not a conversation, and it teaches the model
  # to answer the way it answered before. Rewriting the seed's tone changed one
  # copy and left nine demonstrations of the old voice underneath, which is why
  # tone edits looked like they hadn't taken until the thread was reset.
  describe "quick-action seeds" do
    def tapped(action, body: "a very long block of briefing instructions", mood: nil)
      meta = { "kind" => "buddy_trigger", "hidden" => true, "buddy_action" => action }
      meta["buddy_mood"] = mood if mood
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: body, metadata: meta,
      )
    end

    it "replays the label they tapped instead of the instructions behind it" do
      tapped("today")

      expect(build.first[:content]).to eq("[tapped Today - asked for a briefing on the day ahead]")
    end

    it "keeps the exchange readable, so the reply still has something to answer" do
      tapped("today")
      said("Morning! Here's your day.", direction: :inbound, kind: "buddy")

      expect(build.pluck(:role)).to eq(%i[user assistant])
      expect(build.first[:content]).to include("Today")
    end

    # Collapsing the seed stopped the instructions being re-taught, but left the
    # BRIEFINGS - and a run of past briefings is a worked example of how to
    # write the next one, which is why the same droning list of chore names
    # survived several rewrites of the rule forbidding it. Prod 2756 did it on a
    # freshly reset thread, so the seed was at fault there too; this is the
    # other half.
    describe "older briefings" do
      before do
        tapped("today")
        said("Old briefing, in the old voice.", direction: :inbound, kind: "buddy")
        said("thanks")
        said("Anytime!", direction: :inbound, kind: "buddy")
        tapped("today")
        said("Newer briefing.", direction: :inbound, kind: "buddy")
      end

      it "drops all but the most recent one" do
        contents = build.pluck(:content)

        expect(contents).not_to include("Old briefing, in the old voice.")
        expect(contents).to include("Newer briefing.")
      end

      it "leaves ordinary conversation between them alone" do
        expect(build.pluck(:content)).to include("thanks", "Anytime!")
      end

      it "keeps a lone briefing, since there's no pattern in one" do
        convo.byte_messages.destroy_all
        tapped("today")
        said("The only briefing.", direction: :inbound, kind: "buddy")

        expect(build.pluck(:content)).to include("The only briefing.")
      end

      # The turn being answered is live, not history, however it was started.
      it "never drops the message being answered" do
        seed = tapped("today")

        expect(build(upto: seed).last[:content]).to include("Today")
      end
    end

    it "carries the mood on a check-in, which is the one thing that varies" do
      tapped("checkin", mood: "rough")

      expect(build.first[:content]).to eq("[tapped Check-in, feeling rough]")
    end

    it "names an action it doesn't have a phrase for rather than dumping the seed" do
      tapped("something_new")

      expect(build.first[:content]).to eq("[tapped something_new]")
    end

    # Nine identical 4.5KB prompts is most of what a long Buddy thread costs.
    it "stops re-sending the same instructions once per briefing" do
      3.times { tapped("today", body: "x" * 4_500) }

      expect(build.sum { |item| item[:content].to_s.length }).to be < 500
    end

    # A watch firing or a relay coming in is also a seed, but a short one whose
    # words ARE the message. Those stay exactly as they are.
    it "leaves a seed that isn't a quick action alone" do
      said("[nothing was said to you] The deploy just finished", kind: "buddy_trigger")

      expect(build.first[:content]).to include("The deploy just finished")
    end
  end

  describe "exclusions" do
    it "leaves out receipt chips so Buddy does not learn to narrate receipts" do
      said("Marked the dishes done ✓", direction: :inbound, kind: "buddy_activity")

      expect(build).to be_empty
    end

    it "leaves out system and action-request messages" do
      said("cleared Claude session", direction: :inbound, kind: "system")
      said("Approve Bash?", direction: :inbound, kind: "action-request")

      expect(build).to be_empty
    end

    it "leaves out a half-written streaming reply" do
      said("I was saying someth", direction: :inbound, kind: "buddy", state: :streaming)

      expect(build).to be_empty
    end

    it "leaves out a failed reply" do
      said(Buddy::GPT::Turn::FAILURE_BODY, direction: :inbound, kind: "buddy", state: :failed)

      expect(build).to be_empty
    end

    it "leaves out blank bodies" do
      said("   ", direction: :inbound, kind: "buddy")

      expect(build).to be_empty
    end
  end

  # Buddy::FormAction posts a form card as `kind: "buddy_reply"`, so it used to
  # replay as an assistant turn. Prod 19 Aug: ten chore forms against eight real
  # replies, and Byte answered a correction with "Kk! I marked `Make Meal` off
  # instead of logging it." followed, on its own line, by "Who did: Puppy Up?" -
  # prose, no form, no metadata, copied off the ten above it. The person said
  # "Huh?".
  describe "form cards" do
    def form(body, form_meta)
      convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: body,
        metadata: { "kind" => "buddy_reply", "source" => "form", "form" => form_meta }
      )
    end

    it "does not replay as something Buddy said" do
      form("Who did: Puppy Up?", { "status" => "submitted", "decided" => "submit" })

      expect(build.first[:content]).not_to eq("Who did: Puppy Up?")
    end

    # It can't just vanish: a form Buddy raised mid-conversation is a question
    # the person answered, and "yeah, that one" needs something to point at.
    it "survives as a bracketed standin, so a reference back still lands" do
      form("Who did: Puppy Up?", { "status" => "submitted", "decided" => "submit" })

      expect(build).to eq([
        { role: :assistant, content: "[form you put up: Who did: Puppy Up? - answered]" },
      ])
    end

    it "says which ones are still open" do
      form("Who did: Puppy Fed?", { "status" => "pending" })

      expect(build.first[:content]).to end_with("- unanswered]")
    end

    it "says which ones were declined" do
      form("Who did: Puppy Down?", { "status" => "submitted", "decided" => "skip" })

      expect(build.first[:content]).to end_with("- skipped]")
    end

    it "does not touch an ordinary reply" do
      said("Kk! On the agenda for tonight.", direction: :inbound, kind: "buddy_reply")

      expect(build).to eq([{ role: :assistant, content: "Kk! On the agenda for tonight." }])
    end
  end

  describe "bridged relay messages" do
    it "includes a message received from the partner, attributed" do
      said("I fed the dog", direction: :inbound, kind: "buddy_relay", source: "relay", peer: "Byte")

      expect(build).to eq([
        { role: :assistant, content: "[relayed to you from Byte] I fed the dog" },
      ])
    end

    it "includes the sender-side copy with outgoing framing" do
      said("running late", direction: :inbound, kind: "buddy_relay", source: "relay_copy", peer: "Moss")

      expect(build.first[:content]).to eq("[you passed this along to Moss] running late")
    end

    it "falls back to a neutral label when the peer identity is missing" do
      said("hi", direction: :inbound, kind: "buddy_relay", source: "relay")

      expect(build.first[:content]).to include("their companion")
    end

    it "keeps a bare answer next to the question it answers" do
      # The regression this exists for: with relays excluded, Buddy saw only
      # "tacos" and had nothing to attach it to.
      said("What do you want for dinner?", direction: :inbound, kind: "buddy_relay", source: "relay", peer: "Byte")
      said("tacos")

      expect(build.pluck(:role)).to eq([:assistant, :user])
      expect(build.first[:content]).to include("What do you want for dinner?")
    end
  end

  describe "compaction boundary" do
    it "starts after buddy_recap_at so a compacted stretch is not replayed" do
      said("ancient history")
      convo.update!(metadata: { "buddy_recap_at" => Time.current.iso8601(6) })
      said("after the compact")

      expect(build.pluck(:content)).to eq(["after the compact"])
    end

    it "ignores an unparseable recap timestamp rather than dropping everything" do
      said("still here")
      convo.update!(metadata: { "buddy_recap_at" => "not a time" })

      expect(build.pluck(:content)).to eq(["still here"])
    end

    # Prod 2240. Buddy::TurnDispatcher compacts AFTER the inbound row exists, so
    # the stamp always lands a second or two past it, and the window between the
    # boundary and the message being answered is empty. OpenAI rejects an empty
    # input outright, so the turn that triggers a compaction is the turn that
    # dies — every time.
    it "keeps the message being answered even when the recap lands after it" do
      said("ancient history")
      asking = said("what's on for today?")
      convo.update!(metadata: { "buddy_recap_at" => 1.second.from_now.iso8601(6) })

      expect(build(upto: asking).pluck(:content)).to eq(["what's on for today?"])
    end

    it "never hands back an empty input for a real message" do
      asking = said("anything at all")
      convo.update!(metadata: { "buddy_recap_at" => 1.hour.from_now.iso8601(6) })

      expect(build(upto: asking)).not_to be_empty
    end
  end

  describe "upto" do
    it "stops at the message being answered" do
      first = said("one")
      said("two")

      expect(build(upto: first).pluck(:content)).to eq(["one"])
    end
  end

  describe "safety cap" do
    it "keeps the most recent messages when a thread runs long" do
      (described_class::MAX_MESSAGES + 10).times { |i| said("msg #{i}") }

      items = build
      expect(items.length).to eq(described_class::MAX_MESSAGES)
      expect(items.last[:content]).to eq("msg #{described_class::MAX_MESSAGES + 9}")
    end
  end

  describe "image attachments (multimodal)" do
    # DiskService#url needs url options; there's no request in a service spec.
    before { ActiveStorage::Current.url_options = { host: "example.com", protocol: "https" } }
    after  { ActiveStorage::Current.url_options = nil }

    def with_image(message, name: "photo.png")
      message.files.attach(io: StringIO.new("png-bytes"), filename: name, content_type: "image/png")
      message
    end

    it "builds a multimodal user turn for the message being answered" do
      msg = with_image(said("what's this?"))

      item = build(upto: msg).first
      expect(item[:role]).to eq(:user)
      expect(item[:content].first).to eq({ type: :input_text, text: "what's this?" })
      image = item[:content].last
      expect(image[:type]).to eq(:input_image)
      expect(image[:image_url]).to be_present
    end

    it "keeps an image-only turn (no caption) instead of dropping it" do
      msg = with_image(said(""))

      item = build(upto: msg).first
      expect(item[:role]).to eq(:user)
      expect(item[:content].pluck(:type)).to eq([:input_image])
    end

    it "leaves a plain text turn as a bare string" do
      msg = said("just text")

      expect(build(upto: msg).first).to eq({ role: :user, content: "just text" })
    end

    # History is rebuilt from scratch every turn, so replaying the pixels would
    # re-fetch and re-bill one photo on every turn for the rest of the thread.
    it "sends the pixels once, then names the image with the id view_image takes" do
      msg  = with_image(said("look at this"), name: "chart.png")
      last = said("and another thing")

      item = build(upto: last).first
      expect(item[:content]).to eq("look at this [image ##{msg.id}: chart.png]")
    end

    it "names an image-only turn rather than dropping it once it's been read" do
      msg = with_image(said(""), name: "chart.png")
      said("and another thing")

      expect(build.first[:content]).to eq("[image ##{msg.id}: chart.png]")
    end
  end
end
