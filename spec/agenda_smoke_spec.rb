require "rails_helper"

RSpec.describe "Agenda removal & build smoke" do
  describe "ListItem schedule removal" do
    it "drops schedule, schedule_next, timezone columns" do
      expect(ListItem.column_names).not_to include("schedule", "schedule_next", "timezone")
    end

    it "does not respond to removed schedule methods" do
      item = ListItem.new
      expect(item).not_to respond_to(:schedule)
      expect(item).not_to respond_to(:schedule=)
      expect(item).not_to respond_to(:schedule_options)
      expect(item).not_to respond_to(:schedule_in_words)
      expect(item).not_to respond_to(:set_next_occurrence)
    end

    it "does not have IceCube loaded" do
      expect(defined?(IceCube)).to be_nil
    end

    it "RescheduleItemsWorker is gone" do
      expect(defined?(RescheduleItemsWorker)).to be_nil
    end

    it "MaterializeAgendasWorker is gone (no pre-materialization)" do
      expect(defined?(MaterializeAgendasWorker)).to be_nil
    end
  end
end
