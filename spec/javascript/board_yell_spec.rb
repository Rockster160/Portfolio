require "rails_helper"

# The yell a board's pet shouts is the newest one standing; one whose time has
# run out is gone even before the server says so.
RSpec.describe "Board yells" do
  let(:now) { Time.utc(2026, 11, 11, 18) }
  let(:yells) {
    [
      { key: "mail", body: "Mail", raised_at: (now - 5.minutes).iso8601(3) },
      { key: "dinner", body: "Dinner", raised_at: (now - 1.minute).iso8601(3), expires_at: (now + 9.minutes).iso8601(3) },
      { key: "old", body: "Old", raised_at: now.iso8601(3), expires_at: (now - 1.second).iso8601(3) },
    ]
  }

  def pick(at)
    result = JsRunner.eval_module(<<~JS)
      const { standingYell } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/dream.js").to_s.to_json});
      const yell = standingYell(#{yells.to_json}, #{(at.to_f * 1000).to_i});
      console.log(JSON.stringify({ key: yell && yell.key }));
    JS
    result["key"]
  end

  it "shows the newest standing yell, skipping one that has run out" do
    expect(pick(now)).to eq("dinner")
  end

  it "falls back to an older one once the newest runs out" do
    expect(pick(now + 10.minutes)).to eq("mail")
  end
end
