require "rails_helper"

# The hero shows the strongest face that wants it, the mood included. A
# dream's is weak: it shows only while nothing else is held and the pet's mood
# is idle, and comes back once the pet is idle again - unless it was raised
# strong enough to beat a mood.
RSpec.describe "Byte hero face strengths" do
  let(:result) {
    JsRunner.eval_module(<<~JS)
      const { initBuddyHero, FACE_STRENGTH } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/hero.js").to_s.to_json});
      const el = { dataset: { buddyAwakeExpression: "neutral", buddyTheme: "byte" }, querySelector: () => null };
      const hero = initBuddyHero({ hero: el });
      const face = () => el.dataset.buddyExpression;
      const out = {};

      hero.setExpression("neutral");
      hero.holdExpression("board-dream", "thinking", FACE_STRENGTH.dream);
      out.idle = face();
      hero.setExpression("happy");
      out.mood = face();
      hero.setExpression("neutral");
      out.idle_again = face();
      hero.holdExpression("board-alert", "pounce", FACE_STRENGTH.alert);
      out.alert = face();
      hero.releaseExpression("board-alert");
      out.alert_gone = face();
      hero.releaseExpression("board-dream");
      out.dream_gone = face();

      hero.setExpression("happy");
      hero.holdExpression("board-dream", "eager", FACE_STRENGTH.mood + 5);
      out.strong_dream = face();
      hero.holdExpression("board-alert", "pounce", FACE_STRENGTH.mood - 5);
      out.weak_alert = face();
      hero.holdExpression("whisper", "hiding", FACE_STRENGTH.whisper);
      out.whisper = face();

      process.stdout.write(JSON.stringify(out));
    JS
  }

  it "thinks over an idle mood" do
    expect(result["idle"]).to eq("thinking")
    expect(result["idle_again"]).to eq("thinking")
  end

  it "gives way to any real mood" do
    expect(result["mood"]).to eq("happy")
  end

  it "gives way to a held face, and returns after it" do
    expect(result["alert"]).to eq("pounce")
    expect(result["alert_gone"]).to eq("thinking")
  end

  it "shows a dream over a real mood when it was raised stronger than one" do
    expect(result["strong_dream"]).to eq("eager")
  end

  it "keeps the stronger face when a weaker alert arrives, and gives way to Whisper's state" do
    expect(result["weak_alert"]).to eq("eager")
    expect(result["whisper"]).to eq("hiding")
  end

  it "rests on the mood once the dream is gone" do
    expect(result["dream_gone"]).to eq("neutral")
  end

  # A tap's laugh shows for a moment over everything, and whatever changed
  # underneath meanwhile shows when it ends.
  describe "a flash" do
    let(:flash) {
      JsRunner.eval_module(<<~JS)
        globalThis.window = globalThis;
        const { initBuddyHero, FACE_STRENGTH } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/hero.js").to_s.to_json});
        const el = { dataset: { buddyAwakeExpression: "neutral", buddyTheme: "byte" }, querySelector: () => null };
        const hero = initBuddyHero({ hero: el });
        const face = () => el.dataset.buddyExpression;
        const wait = (ms) => new Promise((r) => setTimeout(r, ms));
        const out = {};

        hero.setExpression("neutral");
        hero.holdExpression("board-dream", "thinking", FACE_STRENGTH.dream);
        hero.flashExpression("grin", 30);
        out.over_dream = face();
        hero.setExpression("happy");
        hero.releaseExpression("board-dream");
        out.through_changes = face();
        await wait(60);
        out.after = face();

        hero.flashExpression("grin", 30);
        hero.setExpression("thinking", { transient: true });
        out.ended_by_thinking = face();
        await wait(60);
        out.thinking_kept = face();

        process.stdout.write(JSON.stringify(out));
      JS
    }

    it "shows over a dream and through a mood change, then settles on the new mood" do
      expect(flash["over_dream"]).to eq("grin")
      expect(flash["through_changes"]).to eq("grin")
      expect(flash["after"]).to eq("happy")
    end

    it "gives way to a transient overlay" do
      expect(flash["ended_by_thinking"]).to eq("thinking")
      expect(flash["thinking_kept"]).to eq("thinking")
    end
  end
end
