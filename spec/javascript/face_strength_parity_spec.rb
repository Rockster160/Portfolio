require "rails_helper"

# The board picks the face it opens on in Ruby and settles in JS; the two must
# rank the same things the same way or the pet changes face once the page loads.
RSpec.describe "Face strength parity" do
  it "holds the JS table to Buddy::FaceStrength" do
    js = JsRunner.eval_module(<<~JS)
      const { FACE_STRENGTH } = await import(#{Rails.root.join("app/javascript/src/pages/byte/buddy/face_strength.js").to_s.to_json});
      process.stdout.write(JSON.stringify(FACE_STRENGTH));
    JS

    ruby = %i[idle dream mood alert sleep].to_h { |name|
      [name.to_s, Buddy::FaceStrength.const_get(name.upcase)]
    }
    expect(js).to eq(ruby)
  end
end
