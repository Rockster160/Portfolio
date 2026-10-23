require "rails_helper"

# `Buddy.mood` with no groups is a look on the person's own pet, worn in their
# own threads; one with groups belongs to the boards those groups name.
RSpec.describe "Own pet moods" do
  let(:result) {
    JsRunner.eval_module(<<~JS)
      const { initOwnMoods } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/own_moods.js").to_s.to_json});
      const calls = [];
      const hero = {
        holdExpression: (key, faces, strength) => calls.push(["hold", key, faces, strength]),
        releaseExpression: (key) => calls.push(["release", key]),
      };
      const sick = { key: "sick", body: null, faces: { byte: "sad" }, strength: 20, groups: [] };
      const board = { key: "whisper", body: null, faces: { byte: "eager" }, strength: 60, groups: ["Whisper"] };
      const words = { key: "gate", body: "Gate open", faces: { byte: "playful" }, groups: [] };

      const own = initOwnMoods({ hero, board: false });
      own.setAlerts([sick, board, words]);
      const held = calls.splice(0);
      own.setAlerts([]);
      const released = calls.splice(0);

      initOwnMoods({ hero, board: true }).setAlerts([sick]);
      process.stdout.write(JSON.stringify({ held, released, onBoard: calls }));
    JS
  }

  it "holds only a wordless look aimed at no board, at its own strength" do
    expect(result["held"]).to eq([["hold", "own-mood:sick", { "byte" => "sad" }, 20]])
  end

  it "lets it go once it no longer stands" do
    expect(result["released"]).to eq([["release", "own-mood:sick"]])
  end

  it "never wears one on a board" do
    expect(result["onBoard"]).to be_empty
  end
end
