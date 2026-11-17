require "rails_helper"

RSpec.describe PrettyLoggerShortTokens do
  let(:token) { "c4Df#{"A" * 2392}tEMn" }
  let(:request) {
    instance_double(
      ActionDispatch::Request,
      path:                "/byte/incoming",
      filtered_parameters: {
        "action" => "create",
        "image"  => token,
        "nested" => { "list" => ["Bearer #{token}", "short"] },
        "note"   => "#{"word " * 40}stays readable",
      }.with_indifferent_access,
    )
  }
  let(:shown) { PrettyLogger::RequestLogger.new(request: request).params }

  it "shortens a long token to its ends and length wherever it sits" do
    expect(shown[:image]).to eq("c4Df..2400c..tEMn")
    expect(shown[:nested][:list]).to eq(["Bearer c4Df..2400c..tEMn", "short"])
  end

  it "leaves ordinary text alone, however long" do
    expect(shown[:note]).to eq("#{"word " * 40}stays readable")
    expect(shown).not_to have_key(:action)
  end

  it "leaves a 99-character run whole" do
    allow(request).to receive(:filtered_parameters).and_return({ "key" => "a" * 99 }.with_indifferent_access)

    expect(shown[:key]).to eq("a" * 99)
  end
end
