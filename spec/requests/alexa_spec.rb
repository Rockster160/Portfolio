RSpec.describe Api::V1::AlexaController, type: :controller do
  let!(:user) { User.me }
  let!(:shopping_list) { user.lists.create!(name: "Shopping") }
  let(:house) {
    ::Doorkeeper::Application.create!(
      name: "Alexa Skill",
      redirect_uri: "https://alexa.com",
      scopes: :access,
    )
  }
  let!(:door) {
    ::Doorkeeper::AccessToken.create(
      application: house,
      resource_owner_id: user.id,
      scopes: :access
    ).tap { |d| d.update!(token: ENV["TEST_EXAMPLE_ALEXA_TOKEN"]) }
  }
  let(:responses) {
    {
      add_bread_to_shopping:       "Shopping:\n - bread",
      log_1:                       "Logged 1",
      log_shower:                  "Logged Shower",
      open_the_garage:             "I don't know how to open the garage, sir.",
      start_the_car:               "Starting car",
      turn_off_the_kitchen_lights: "I don't know how to turn off the kitchen lights, sir.",
    }
  }

  describe "POST #alexa" do
    before do
      request.headers["Content-Type"] = "application/json"
      request.headers["Accept"] = "application/json"
    end

    Dir.glob("_scripts/alexa/examples/*.json").each do |file|
      filename = File.basename(file, ".json")
      json_data = File.read(file)
      data = JSON.parse(json_data)

      it "asks via proxy: #{filename}" do
        post :alexa, params: data

        expect(response).to have_http_status(:success)

        json = JSON.parse(response.body, symbolize_names: true)
        words = json.dig(:response, :outputSpeech, :text)
        expect(words).to eq(responses[filename.to_sym])
      end
    end
  end
end
