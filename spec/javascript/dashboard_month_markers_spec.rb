require "rails_helper"

# The Month cell dots the day something last happened in red, its next due day
# in red, and the day a week before that in orange. The grid runs into the
# first days of next month, so a warning can land on a day showing while the
# due date it warns about is still past the last row.
RSpec.describe "dashboard Month markers (JS-side)" do
  let(:result) {
    JsRunner.output("spec/javascript/dashboard_month_markers_runner.js")
  }

  it "shows the warning on next month's days when the due date is past the grid" do
    expect(result["due_past_the_grid"]).to eq(
      "this 11" => "red",
      "next 2"  => "orange",
    )
  end

  it "shows a due date on the grid with its warning a week before" do
    expect(result["due_on_the_grid"]).to eq(
      "this 18" => "orange",
      "this 25" => "red",
    )
  end

  it "shows only the last occurrence when the warning is past the grid too" do
    expect(result["warn_past_the_grid"]).to eq("this 20" => "red")
  end
end
