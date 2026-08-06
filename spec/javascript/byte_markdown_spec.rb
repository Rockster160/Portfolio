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

  # Byte can hand over a page, and a tap has to leave the app rather than
  # replacing the conversation with something that has no back button — the
  # thread is an installed PWA in standalone mode.
  describe "links" do
    it "turns markdown link syntax into an anchor" do
      expect(rendered["md_link"])
        .to include(%(href="https://ardesian.com/chores/links"), ">your links page</a>")
    end

    it "opens outside the app rather than in the Byte tab" do
      expect(rendered["md_link"]).to include(%(target="_blank"), %(rel="noopener noreferrer"))
    end

    it "links a bare URL too" do
      expect(rendered["bare_url"]).to include(%(<a class="byte-md-link" href="https://ardesian.com/chores"))
    end

    # The reason links are stashed before the emphasis rules run.
    it "leaves underscores in a URL alone" do
      expect(rendered["url_with_underscores"]).to include("/a_b_c/d_e</a>")
      expect(rendered["url_with_underscores"]).not_to include("<em>")
    end

    it "ends the link at the full stop, not after it" do
      expect(rendered["url_trailing_period"]).to include(%(href="https://ardesian.com/chores"))
      expect(rendered["url_trailing_period"]).to end_with("</a>.")
    end

    it "keeps a query string intact" do
      expect(rendered["url_query_amp"]).to include(%(href="https://ardesian.com/s?a=1&amp;b=2"))
    end

    # This output goes to innerHTML and the body is model-written, so a scheme
    # that can execute is a script the model got to choose.
    it "refuses a javascript: href, leaving the text as written" do
      expect(rendered["javascript_href"]).not_to include("<a")
      expect(rendered["javascript_href"]).to include("javascript:alert(1)")
    end

    it "refuses a data: href" do
      expect(rendered["data_href"]).not_to include("<a")
      expect(rendered["data_href"]).not_to include("<script>")
    end

    it "escapes markup in the link text" do
      expect(rendered["link_text_escaped"]).to include("&lt;b&gt;x&lt;/b&gt;</a>")
    end

    it "leaves a URL inside inline code as code" do
      expect(rendered["url_in_code_untouched"]).not_to include("<a")
      expect(rendered["url_in_code_untouched"]).to include("byte-md-inline")
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
