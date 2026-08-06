require "rails_helper"
require "json"
require "open3"

# Prod 2620 and the few after it came out with raw `_glue_` and raw `- ` bullets
# on screen: the thread's markdown-lite did `**bold**` and `*italic*` and
# nothing else, so everything the model wrote in the other notation arrived as
# punctuation.
#
# The underscore rule is the reason this is a real test rather than a glance.
# `_glue_` is emphasis and `game_tray-vase` is a filename, and this app is full
# of the second kind.
RSpec.describe "Byte thread markdown" do
  let(:rendered) {
    runner = Rails.root.join("spec/javascript/byte_markdown_runner.js").to_s
    stdout, stderr, status = Open3.capture3("node", runner)
    raise "runner failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  }

  describe "underscore emphasis" do
    it "italicises a word wrapped in underscores" do
      expect(rendered["underscore_em"]).to include("the <em>glue</em>.")
    end

    it "works mid-sentence" do
      expect(rendered["underscore_mid_sentence"]).to include("<em>structured</em>")
    end

    it "works after an opening bracket" do
      expect(rendered["underscore_in_parens"]).to include("(<em>maybe</em>)")
    end

    # The whole reason for the word-boundary anchors.
    it "leaves a snake_case filename alone" do
      expect(rendered["snake_case_left_alone"]).to eq("printing game_tray-vase now")
    end

    it "leaves two snake_case words on one line alone" do
      expect(rendered["two_snake_case_words"]).not_to include("<em>")
    end
  end

  describe "bullet lists" do
    it "turns consecutive dashed lines into one list" do
      html = rendered["bullet_list"]

      expect(html).to include("<ul class=\"byte-md-list\"><li>one thing</li><li>two thing</li></ul>")
    end

    it "doesn't leave a stray break between the list and what follows" do
      expect(rendered["bullet_then_text"]).to eq("<ul class=\"byte-md-list\"><li>only item</li></ul>after")
    end

    # Byte is told to use " - " instead of an em dash, so a mid-line hyphen is
    # ordinary prose and must not start a list.
    it "leaves a hyphen in the middle of a sentence alone" do
      expect(rendered["dash_midline_not_a_list"]).to eq("it went out - and she has it now")
    end
  end

  describe "what already worked" do
    it "still does asterisk italics" do
      expect(rendered["asterisk_em_still_works"]).to include("<em>very</em>")
    end

    it "still does bold, underscores and all" do
      expect(rendered["bold_still_works"]).to include("<strong>game_tray-vase</strong>")
    end

    it "still leaves inline code untouched" do
      expect(rendered["inline_code_untouched"])
        .to include("<code class=\"byte-md-inline\">item:name:/Permission/</code>")
    end
  end
end
