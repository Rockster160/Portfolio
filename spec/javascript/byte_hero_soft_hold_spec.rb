require "rails_helper"

# A dream's face is a SOFT hold on the hero: it shows only while nothing else
# is held and the pet's mood is idle. Any real face takes over, and the dream's
# comes back once the pet is idle again.
RSpec.describe "Byte hero soft holds" do
  let(:result) {
    JsRunner.eval_module(<<~JS)
      const { initBuddyHero, HOLD_PRIORITY } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/hero.js").to_s.to_json});
      const el = { dataset: { buddyAwakeExpression: "neutral", buddyTheme: "byte" }, querySelector: () => null };
      const hero = initBuddyHero({ hero: el });
      const face = () => el.dataset.buddyExpression;
      const out = {};

      hero.setExpression("neutral");
      hero.holdExpression("board-dream", "thinking", HOLD_PRIORITY.dream, { soft: true });
      out.idle = face();
      hero.setExpression("happy");
      out.mood = face();
      hero.setExpression("neutral");
      out.idle_again = face();
      hero.holdExpression("board-alert", "pounce", HOLD_PRIORITY.alert);
      out.alert = face();
      hero.releaseExpression("board-alert");
      out.alert_gone = face();
      hero.releaseExpression("board-dream");
      out.dream_gone = face();

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

  it "rests on the mood once the dream is gone" do
    expect(result["dream_gone"]).to eq("neutral")
  end
end
