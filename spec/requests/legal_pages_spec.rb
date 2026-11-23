require "rails_helper"

RSpec.describe "Privacy policy and support pages", type: :request do
  it "shows the privacy policy to anyone, naming who handles what", :aggregate_failures do
    get privacy_policy_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Privacy Policy", "Apple Health", "Anthropic", "contact@ardesian.com")
    expect(User.guest).to be_empty
  end

  it "shows support with the install link once there is one" do
    AppDevice.install_url = "https://testflight.apple.com/join/AbCd1234"

    get support_path

    expect(response.body).to include("Buddy Support", "https://testflight.apple.com/join/AbCd1234")
  end
end
