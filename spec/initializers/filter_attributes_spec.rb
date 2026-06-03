require "rails_helper"

RSpec.describe "image_data filtering" do
  it "masks image_data in ActiveRecord inspect output" do
    icon = HouseholdIcon.new(name: "X", image_data: "data:image/png;base64," + ("A" * 500))
    expect(icon.inspect).to include("image_data: [FILTERED]")
    expect(icon.inspect).not_to include("AAAAA")
  end
end
