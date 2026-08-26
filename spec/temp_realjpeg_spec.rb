require "rails_helper"

# Scaffolding: prod says frame keys=[] on a payload whose head and tail are both
# intact. Reproduce with a REAL jpeg's base64, not random bytes. DELETE after.
RSpec.describe "Jil Hash parse on an actual JPEG" do
  JPEG = "/private/tmp/claude-501/-Users-zoro-code-Portfolio/9b49d04c-b367-45f7-9cd0-c3e0daf471b3/scratchpad/real.jpg".freeze

  def frame_json(b64)
    {
      ok: true, camera: "camera.doorbell_fluent", source: "live", requested: "now",
      captured_at: "2026-08-25T18:57:33", event: "", off_by_seconds: 0, note: "",
      bytes: 348_186, shrunk: nil, image_b64: b64,
    }.to_json
  end

  it "parses a real jpeg frame" do
    b64 = Base64.strict_encode64(File.binread(JPEG))
    json = frame_json(b64)
    out = begin
      Jil::Methods::Hash.parse(json)
    rescue StandardError => e
      "RAISED #{e.class}: #{e.message[0, 100]}"
    end
    got = out.is_a?(::Hash) ? "ok=#{out[:ok].inspect} keys=#{out.keys.length}" : out.to_s[0, 120]
    puts ">>> real jpeg b64=#{b64.length} → #{got}"
  end

  # Bisect: which slice of the real base64 breaks it?
  it "bisects the real base64 to the offending region" do
    b64 = Base64.strict_encode64(File.binread(JPEG))
    [1_000, 10_000, 50_000, 100_000, 235_212].each do |take|
      slice = b64[0, take]
      out = begin
        Jil::Methods::Hash.parse(frame_json(slice))
      rescue StandardError => e
        "RAISED #{e.class}"
      end
      got = out.is_a?(::Hash) ? "keys=#{out.keys.length}" : out.to_s[0, 60]
      puts ">>> take #{take.to_s.rjust(7)} → #{got}"
    end
  end

  # Named suspects, isolated.
  it "tries the substrings a real jpeg has and random bytes do not" do
    {
      "plain"            => "AAAA",
      "double slash"     => "AA//Z",
      "contains nil"     => "AAnilAA",
      "contains true"    => "AAtrueAA",
      "long U run"       => "#{'U' * 200}",
      "colon space"      => "AA: AA",
      "word colon space" => "abc: def",
    }.each do |label, payload|
      out = begin
        Jil::Methods::Hash.parse({ ok: true, image_b64: payload }.to_json)
      rescue StandardError => e
        "RAISED #{e.class}"
      end
      got = out.is_a?(::Hash) ? "ok=#{out[:ok].inspect} b64=#{out[:image_b64].to_s[0, 24].inspect}" : out.to_s[0, 60]
      puts ">>> #{label.ljust(18)} → #{got}"
    end
  end
end
