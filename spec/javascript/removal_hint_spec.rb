require "rails_helper"

# The line under a checklist row that removes something.
#
# A tickbox means "yes, this one" everywhere else, so a ticked box beside
# "Remove oat milk" reads two ways at once - and once the row has run, UNticking
# is what puts the thing back, which is tick-to-delete and untick-to-restore in
# the same control. These rows say which it is in words.
RSpec.describe "Checklist removal hints" do
  let(:result) { JsRunner.output("spec/javascript/removal_hint_runner.js") }

  describe "before it's been tapped" do
    it "says the tick is what does the removing" do
      expect(result["pending"]["cancel_reminder"]).to eq("Tap to cancel it")
      expect(result["pending"]["delete_event"]).to eq("Tap to delete it")
      expect(result["pending"]["remove_list_item"]).to eq("Tap to remove it")
    end

    it "uses the word that fits the thing rather than one blanket verb" do
      expect(result["pending"]["forget_routine"]).to eq("Tap to forget it")
      expect(result["pending"]["unlink_records"]).to eq("Tap to unlink them")
      expect(result["pending"]["undo_chore_completion"]).to eq("Tap to unmark it")
    end

    it "covers every removal tool that can reach a checklist" do
      expect(result["pending"].values).to all(start_with("Tap to"))
    end
  end

  describe "once it has run" do
    # The double negative, spelled out: what happened, then what the box does
    # now. Without it a ticked box over "Remove Check the bamboo tree" is as
    # easily read as "still to do" as "done".
    it "says what happened and that unticking is the way back" do
      expect(result["executed_undoable"]["cancel_reminder"])
        .to eq("Cancelled — untick to put it back")
      expect(result["executed_undoable"]["delete_event"])
        .to eq("Deleted — untick to put it back")
      expect(result["executed_undoable"]["remove_list_item"])
        .to eq("Removed — untick to put it back")
    end

    it "keeps the reversal in the same words as the removal" do
      expect(result["executed_undoable"]["unlink_records"])
        .to eq("Unlinked — untick to link them again")
      expect(result["executed_undoable"]["undo_chore_completion"])
        .to eq("Unmarked — untick to mark it again")
    end

    it "never leads with the past tense on a row that hasn't run" do
      expect(result["pending"].values).to all(satisfy { |hint| hint.exclude?("untick") })
    end
  end

  describe "rows that get no line" do
    # A tick on an additive row already means the obvious thing, and a caption
    # under every row is noise that stops being read.
    it "leaves additive rows alone" do
      %w[log_event complete_chore add_list_item create_chore].each do |tool|
        expect(result["silent"][tool]).to be_nil
      end
    end

    it "gives none to a tool it doesn't know" do
      expect(result["silent"]["unknown_tool"]).to be_nil
      expect(result["silent"]["no_tool"]).to be_nil
    end

    # The box is locked in that case. Offering a way back that isn't there is
    # worse than saying nothing.
    it "promises no untick on a row that ran and can't be reversed" do
      expect(result["silent"]["executed_locked"]).to be_nil
    end

    it "stays quiet on rows that are already finished with" do
      %w[undone failed expired superseded working].each do |status|
        expect(result["silent"][status]).to be_nil
      end
    end

    it "survives being called with no options at all" do
      expect(result["silent"]["no_options"]).to be_nil
    end
  end

  # A card whose rows ARE a list - the before-bed checklist - is every row the
  # same tool, and the tool's own words describe the mechanism ("Tap to remove
  # it") rather than what the person thinks they're doing.
  describe "a row that brought its own words" do
    it "uses them in place of the tool's" do
      expect(result["override"]["pending"]).to eq("Tap when it's done")
      expect(result["override"]["executed"]).to eq("Done - untick to put it back")
    end

    it "can give words to a tool that has none" do
      expect(result["override"]["additive"]).to eq("Tap when it's done")
    end

    # The override says the words, never when they apply — a locked or finished
    # row is still silent, so it can't promise a way back that isn't there.
    it "does not change which rows get a line at all" do
      expect(result["override"]["locked"]).to be_nil
      expect(result["override"]["undone"]).to be_nil
    end
  end
end
