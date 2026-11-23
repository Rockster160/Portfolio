require "rails_helper"

RSpec.describe "Buddy app install link", type: :request do
  def headers_for(user)
    { "Authorization" => "Bearer #{AppDevice.issue!(user, name: "Phone").last}" }
  end

  it "is set by an admin and offered from then on", :aggregate_failures do
    link = "https://testflight.apple.com/join/AbCd1234"

    patch install_link_app_devices_path, params: { install_url: link }, headers: headers_for(User.me)

    expect(response).to redirect_to(app_devices_path)
    expect(AppDevice.install_url).to eq(link)
  end

  it "takes only an https link" do
    patch install_link_app_devices_path, params: { install_url: "http://example.com" }, headers: headers_for(User.me)

    expect(AppDevice.install_url).to be_nil
  end

  it "can't be changed by someone who isn't an admin" do
    patch install_link_app_devices_path, params: { install_url: "https://example.com" }, headers: headers_for(create(:user))

    expect(AppDevice.install_url).to be_nil
  end
end
