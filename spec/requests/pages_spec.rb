require "rails_helper"

RSpec.describe "A page that doesn't exist", type: :request do
  it "is not found, rather than an error" do
    expect { get "/pages/about" }.not_to raise_error
    expect(response.status).not_to eq(500)
    expect(response.body).not_to include("undefined method")
  end
end
