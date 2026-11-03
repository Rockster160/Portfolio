require "rails_helper"

RSpec.describe Buddy::Personality do
  # Ages are counted in local calendar days, so a clock near midnight or a DST
  # change would move "3.weeks.ago" onto a different day.
  around { |example| travel_to(Time.utc(2026, 9, 16, 18, 0)) { example.run } }

  # The pet theme is per-conversation, so the persona is keyed off the buddy
  # conversation's theme, not the user.
  def buddy_convo(user, theme)
    convo = user.byte_conversations.create!(mode: :buddy)
    convo.update!(buddy_theme: theme)
    convo
  end

  describe ".for assembling the prompt" do
    # A term of address is a vocative: clause-final after a comma ("Sorry,
    # love."). "nice, love that for you" is the verb and stays. Naming one in a
    # ban list teaches it just the same.
    let(:endearments) { %w[love babe baby honey hon sweetheart sweetie dear darling cutie] }

    let(:broken_device) {
      /
        \b(?:camera|doorbell|printer|thermostat|blinds?|tv|garage|gate)\b[^.\n]{0,60}
        \b(?:didn(?:'|’)?t|couldn(?:'|’)?t|isn(?:'|’)?t|won(?:'|’)?t|failed|broken|offline|unavailable)\b
      /ix
    }

    # Replies in Buddy's own voice that, once quoted in the prompt, came back
    # out of it as claims about the house.
    let(:echoed) {
      [
        "I couldn't get a frame from the backyard camera",
        "119 chores left",
        "Wednesday at 11:00 AM",
        "Starting the car and setting it to 72.",
        "Lights are off.",
        "Reminder's set for 6.",
        "The gate's been shut since about 9",
        "I don't have a deploy watcher wired up",
        "I can't verify the gate from here",
        "I can't check that from here",
        "I can't change that now that it's marked",
        "I can't make a sound",
        "I've put the person doorbell watch on the remove-row",
        "I parked your tomatoes reminder",
        "the flower bed one is tomorrow at 8",
        "lined up to pop in every half hour until 6:30 PM",
        "I've got a watch on the dryer stop call already",
        "Set for 4 — assuming today.",
        "Put it on the Shopping list, since that's where the food usually goes.",
        "Read that as the front door.",
        "I don't have a `prep printer` routine",
      ]
    }

    it "loads each theme's own persona, fills every placeholder and names no endearment", :aggregate_failures do
      Buddy::Themes.all.each_key do |theme|
        user = theme.to_s == "byte" ? User.me : create(:user)
        prompt = described_class.for(user, conversation: buddy_convo(user, theme.to_s))

        expect(prompt).to include("You are #{theme.to_s.capitalize}."), theme.to_s
        expect(prompt).not_to match(/\{\{[A-Z_]+\}\}/), theme.to_s
        endearments.each { |word|
          expect(prompt).not_to match(/,\s*#{word}\s*["”]?[.!?]/i), "#{theme}: #{word} as an address"
          expect(prompt).not_to match(/`#{word}`/i), "#{theme}: #{word} named in a ban list"
        }
      end
    end

    # The face is read off the conversation by Buddy::Sentiment, so the marker
    # protocol must not come back into the prompt.
    it "hands the model no face marker, echoed reply or claim about a device", :aggregate_failures do
      prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

      expect(prompt).not_to include("[[mood:", "set_mood")
      expect(echoed.select { |line| prompt.include?(line) }).to be_empty
      expect(prompt.scan(broken_device)).to be_empty
    end
  end

  describe ".for what they are carrying" do
    let(:prompt) { described_class.for(User.me, conversation: buddy_convo(User.me, "byte")) }

    def memory(content, **attrs)
      BuddyMemory.create!({ user: User.me, content: content, severity: 70 }.merge(attrs))
    end

    it "carries a heavy thing inline with how long ago it was said" do
      memory("Sandbox: the fig tree in the sandbox is dying", created_at: 3.weeks.ago)

      expect(prompt).to include("(3 weeks) Sandbox: the fig tree in the sandbox is dying")
    end

    # The briefing is a rundown of the day with nothing following it, so the
    # section is not shipped there at all.
    it "is not shipped to the Today briefing" do
      memory("Sandbox: the fig tree in the sandbox is dying")
      briefing = described_class.for(
        User.me, conversation: buddy_convo(User.me, "byte"), briefing: true
      )

      expect(briefing).not_to include("the fig tree in the sandbox is dying")
      expect(briefing).not_to include("What #{User.me.first_name} is carrying")
    end

    it "leaves out light, not-yet-relevant and resolved ones", :aggregate_failures do
      memory("Sandbox: a fig needs picking", severity: BuddyMemory::CARRY_FLOOR - 1)
      memory("Sandbox: the fig tree is being cut down", relevant_at: 2.weeks.from_now)
      memory("Sandbox: the fig tree was dying", status: :done)

      expect(prompt).not_to include("a fig needs picking")
      expect(prompt).not_to include("the fig tree is being cut down")
      expect(prompt).not_to include("the fig tree was dying")
      expect(prompt).not_to include("What #{User.me.first_name} is carrying")
    end

    # Preferences are already inline via `always_loaded`; stash has its own
    # block. Either one here would have the pet reading it twice.
    it "does not repeat a preference or a stashed thought" do
      memory("Sandbox: figs are to be picked by hand", kind: :preference)
      memory("Sandbox: think about a second fig tree", kind: :stash)

      expect(prompt.scan("figs are to be picked by hand").length).to eq(1)
      expect(prompt.scan("think about a second fig tree").length).to eq(1)
    end

    it "stays bounded, heaviest first" do
      (BuddyMemory::CARRY_LIMIT + 2).times { |i| memory("Sandbox: fig #{i}", severity: 51 + i) }

      carried = (0...(BuddyMemory::CARRY_LIMIT + 2)).select { |i| prompt.include?("Sandbox: fig #{i}") }
      expect(carried.length).to eq(BuddyMemory::CARRY_LIMIT)
      expect(carried).not_to include(0)
    end
  end

  # A preference read back in the relative words it was written in reads as
  # though the count started this morning, so each one carries its age.
  it "dates each always-loaded preference by when it was said", :aggregate_failures do
    BuddyMemory.create!(user: User.me, content: "Sandbox: the figs are about 6 days off", kind: :preference, created_at: 5.days.ago)
    BuddyMemory.create!(user: User.me, content: "Sandbox: figs are picked by hand", kind: :preference)

    prompt = described_class.for(User.me, conversation: buddy_convo(User.me, "byte"))

    expect(prompt).to include("(5 days) Sandbox: the figs are about 6 days off")
    expect(prompt).to include("(today) Sandbox: figs are picked by hand")
  end
end
