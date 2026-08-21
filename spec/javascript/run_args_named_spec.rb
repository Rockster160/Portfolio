require "rails_helper"

# A function task's args used to be readable only BY POSITION when the task was
# run from the editor, because a quoted label produced a display string and
# nothing else. Buddy posts the same args under lowercase_snake_case of that
# label, so one task could not be written to satisfy both callers.
#
# Position alone is not enough. `params` is built from the keys the caller
# actually SENT, so a caller that skips an optional middle arg shifts every
# later arg onto the wrong name — "the last time the driveway saw a car" sent
# {camera, event} and the event landed in the timestamp. A label that binds a
# name is what makes an optional arg safe anywhere but last.
RSpec.describe "Run-args modal named binding" do
  let(:result) { JsRunner.output("spec/javascript/run_args_named_runner.js") }

  describe "the key a label posts under" do
    it "lowercases a single word" do
      expect(result.dig("keys", "simple")).to eq("camera")
    end

    # Same transform call_jil_function documents, so Buddy and the modal agree.
    it "underscores a multi-word label" do
      expect(result.dig("keys", "spaced")).to eq("start_time")
    end

    it "trims surrounding space" do
      expect(result.dig("keys", "padded")).to eq("when")
    end
  end

  describe "binding" do
    it "gives a labeled arg a name" do
      expect(result.dig("bindings", "labeled")).to eq("kind" => "named", "name" => "when")
    end

    it "leaves an unlabeled arg positional" do
      expect(result.dig("bindings", "unlabeled")).to eq("kind" => "positional")
    end

    it "treats an empty label as no label" do
      expect(result.dig("bindings", "empty")).to eq("kind" => "positional")
    end
  end

  describe "what gets posted" do
    # Both, always. The named keys are what a task can trust; `params` is what
    # every task written before this one already reads.
    it "posts a labeled arg under its name AND its position" do
      posted = result["labeled_posts_both"]

      expect(posted).to include("camera" => "driveway", "when" => "", "event" => "vehicle")
      expect(posted["params"]).to eq(["driveway", "", "vehicle"])
    end

    it "keeps an omitted middle value in its own slot rather than shifting" do
      expect(result.dig("labeled_posts_both", "params", 1)).to eq("")
      expect(result.dig("labeled_posts_both", "event")).to eq("vehicle")
    end

    it "adds no keys for unlabeled args" do
      posted = result["unlabeled_posts_positionally"]

      expect(posted.keys).to eq(["params"])
      expect(posted["params"]).to eq(%w[a b])
    end

    # `params` is assigned after the loop, so the array wins. Worth pinning:
    # the alternative is an arg named "Params" silently eating the positional
    # list and breaking every positional read in that task.
    it "does not let an arg labeled Params clobber the positional array" do
      expect(result["params_label_does_not_clobber"]["params"]).to eq(["mine"])
    end
  end
end
