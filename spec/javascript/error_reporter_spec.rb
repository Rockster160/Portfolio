require "rails_helper"

# What the browser sends to the error log, and what it keeps to itself.
RSpec.describe "Browser error reporter" do
  let(:result) { JsRunner.output("spec/javascript/error_reporter_runner.js") }

  it "sends an uncaught error with where it happened" do
    expect(result["sent"]).to include(
      "endpoint"  => "/client_errors",
      "url"       => "https://example.com/lists/42?x=1",
      "kind"      => "error",
      "name"      => "TypeError",
      "message"   => "x is undefined",
      "source"    => "https://example.com/assets/application.js:10:2",
      "page"      => "/lists/42",
      "keepalive" => true,
    )
    expect(result["sent"]["stack"]).to include("application.js:10:2")
  end

  it "sends the same failure once per page load" do
    expect(result["after_repeat"]).to eq(1)
  end

  it "keeps cross-origin noise and extensions' failures out" do
    expect(result["after_noise"]).to eq(1)
  end

  it "sends rejected promises, whatever they were rejected with" do
    expect(result["rejections"]).to eq([
      { "kind" => "rejection", "name" => "TypeError", "message" => "fetch failed" },
      { "kind" => "rejection", "name" => "UnhandledRejection", "message" => "{\"status\":500}" },
      { "kind" => "rejection", "name" => "UnhandledRejection", "message" => "[object Object]" },
    ])
  end

  it "stops after a page has sent its share" do
    expect(result["capped"]).to eq(10)
  end
end
