require "rails_helper"

# Prod 2620 and the few after it came out with raw `_glue_` and raw `- ` bullets
# on screen: the thread's markdown-lite did `**bold**` and `*italic*` and
# nothing else, so everything the model wrote in the other notation arrived as
# punctuation.
#
# The underscore rule is the reason this is a real test rather than a glance.
# `_glue_` is emphasis and `game_tray-vase` is a filename, and this app is full
# of the second kind.
RSpec.describe "Byte thread markdown" do
  let(:rendered) { JsRunner.output("spec/javascript/byte_markdown_runner.js") }

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

  # The daily audit is a structured report delivered into a chat thread, so it
  # writes `## Counts` and pipe tables. Both used to arrive as literal
  # punctuation — headings and tables were an explicit non-goal here until a
  # message shape existed that genuinely wanted them.
  describe "headings" do
    it "renders a level-two heading" do
      expect(rendered["heading_h2"]).to include("<h4 class=\"byte-md-h byte-md-h2\">Counts</h4>")
    end

    it "renders levels one and three too" do
      expect(rendered["heading_h1"]).to include("<h3 class=\"byte-md-h byte-md-h1\">Daily Audit</h3>")
      expect(rendered["heading_h3"]).to include("<h5 class=\"byte-md-h byte-md-h3\">Backfills</h5>")
    end

    it "keeps inline formatting inside the heading" do
      expect(rendered["heading_with_bold"]).to include("<strong>Counts</strong> for today</h4>")
    end

    it "drops closing hashes" do
      expect(rendered["heading_closing_hashes"]).to include(">Counts</h4>")
    end

    # A heading is a block; a <br> after it would open a gap.
    it "does not leave a break after itself" do
      expect(rendered["heading_h2"]).not_to include("</h4><br>")
    end

    it "needs a space, so #nothashtag is left alone" do
      expect(rendered["hash_no_space_not_a_heading"]).to eq("#nothashtag stays")
    end

    it "only starts a line, so a mid-sentence # is left alone" do
      expect(rendered["hash_midline_not_a_heading"]).to eq("the count is #4 today")
    end
  end

  describe "tables" do
    it "builds a header and body" do
      html = rendered["table_basic"]

      expect(html).to include("<th>Thread</th><th>In</th><th>Out</th>")
      expect(html).to include("<tr><td>Byte</td><td>40</td><td>21</td></tr>")
      expect(html).to include("<tr><td>Moss</td><td>6</td><td>4</td></tr>")
    end

    # A wide table must scroll inside itself; the thread must never scroll
    # sideways.
    it "wraps the table in its own scroller" do
      expect(rendered["table_basic"]).to include("<div class=\"byte-md-table-wrap\">")
    end

    it "honours alignment colons" do
      expect(rendered["table_aligned"]).to include("<th class=\"is-right\">Count</th>")
    end

    it "keeps inline formatting inside cells" do
      html = rendered["table_with_inline"]

      expect(html).to include("<td><strong>Byte</strong></td>")
      expect(html).to include("byte-md-inline")
    end

    it "doesn't swallow the line after it" do
      expect(rendered["table_then_text"]).to end_with("after the table")
      expect(rendered["table_then_text"]).not_to include("<br>after")
    end

    # The separator row is what makes it a table. Without it, an ordinary
    # sentence containing a pipe would start eating the lines below it.
    it "leaves pipes alone when there is no separator row" do
      expect(rendered["pipes_without_separator"]).not_to include("<table")
    end

    it "works straight after a heading" do
      html = rendered["table_after_heading"]

      expect(html).to include("</h4>")
      expect(html).to include("<table class=\"byte-md-table\">")
      expect(html).not_to include("<br>")
    end
  end

  # An icon is written three ways and rendered in two places — a message body
  # (full markdown) and a tool-argument preview (icons only, everything else
  # escaped). Both come out as an EMPTY span carrying the reference; the picture
  # is put in afterwards, once the icon pool is loaded.
  describe "icon references" do
    def ref(html)
      html[/data-icon-ref="([^"]*)"/, 1]
    end

    it "takes an id" do
      expect(ref(rendered["hicon_by_id"])).to eq("hicon:24")
    end

    # Prod: this arrived typed with a space and rendered as literal brackets.
    it "takes an id with a space after the colon" do
      expect(ref(rendered["hicon_id_spaced"])).to eq("hicon:21")
    end

    it "takes a name" do
      expect(ref(rendered["hicon_by_name"])).to eq("Fae")
    end

    it "takes a name with spaces in it" do
      expect(ref(rendered["hicon_name_with_spaces"])).to eq("Mtn Dew Can")
    end

    it "takes a Tabler class" do
      expect(ref(rendered["ticon"])).to eq("ti-broom")
    end

    it "renders each one in a run of them" do
      expect(rendered["hicon_three_in_a_row"].scan(/data-icon-ref/).length).to eq(3)
    end

    # The link rule would swallow `[hicon Fae](...)` whole if it ran first.
    it "isn't turned into a link by a following parenthetical" do
      html = rendered["hicon_then_parens"]

      expect(ref(html)).to eq("Fae")
      expect(html).not_to include("<a ")
    end

    it "leaves one inside a code span alone" do
      expect(rendered["hicon_in_code_untouched"]).to include(">[hicon Fae]</code>")
    end

    it "leaves a shape that isn't a reference as text" do
      expect(rendered["hicon_unknown_shape_left_alone"]).to eq("[hicon]")
    end

    it "comes out empty, for the pool to fill" do
      expect(rendered["hicon_by_id"]).to include('data-icon-ref="hicon:24"></span>')
    end

    describe "the narrow pass, for text that isn't markdown" do
      it "still resolves every written form" do
        expect(ref(rendered["ref_id"])).to eq("hicon:24")
        expect(ref(rendered["ref_id_spaced"])).to eq("hicon:21")
        expect(ref(rendered["ref_name"])).to eq("Fae")
      end

      it "escapes everything around them" do
        expect(rendered["ref_escapes_html"]).to include("&lt;b&gt;x&lt;/b&gt;")
      end

      # A tool argument is not prose: an underscore in a chore name is an
      # underscore, not the start of emphasis.
      it "leaves markdown notation as written" do
        expect(rendered["ref_leaves_markdown_alone"]).to include("a _b_ c **d**")
      end

      it "is a plain escape when there's nothing to find" do
        expect(rendered["ref_none"]).to eq("just plain text")
      end
    end
  end

  # The receipt under a ticked row went in as textContent, so when a logged job
  # note started linking the row it wrote, the person got "Logged **Rejected**
  # on [Corporate Tools](https://ardesian.com/interviews/12)" on screen exactly
  # as written. Worse than no link: the address is in front of them, twice the
  # length of the words, and still not clickable.
  describe "the one-line pass" do
    it "renders bold and a link in a receipt" do
      html = rendered["inline_receipt"]

      expect(html).to include("<strong>Rejected</strong>")
      expect(html).to include(%(href="https://ardesian.com/interviews/12"))
      expect(html).to include(">Corporate Tools</a>")
    end

    it "links a bare url" do
      expect(rendered["inline_bare_url"]).to include(%(href="https://ardesian.com/interviews/12"))
    end

    # A checkbox label is one line. Every block construct is left as the
    # punctuation it was written with.
    it "leaves a leading dash as a dash" do
      expect(rendered["inline_dash_is_not_a_list"]).not_to include("<ul")
    end

    it "leaves a newline flat" do
      expect(rendered["inline_newline_stays_flat"]).not_to include("<br>")
    end

    it "leaves hashes alone" do
      expect(rendered["inline_heading_is_not_a_heading"]).to eq("## not a heading")
    end

    it "escapes html it did not render" do
      expect(rendered["inline_escapes_html"]).to eq("&lt;b&gt;x&lt;/b&gt; logged")
    end

    # Same rule as the body: a receipt is assembled from model output.
    it "refuses an unsafe scheme" do
      expect(rendered["inline_javascript_href"]).not_to include("<a")
    end

    it "still substitutes an icon" do
      expect(rendered["inline_hicon"]).to include(%(data-icon-ref="Fae"))
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

  # FeatureRequest 4, written 4 Sep four minutes after a "Time to go" notice
  # read out a clinic's address in full: "addresses should be linked so that I
  # can click to open them in maps."
  #
  # The agenda's details modal has done this since June, but that reads a
  # location FIELD whose whole value is the address. Here it has to be found
  # inside a sentence a Jil task composed, which is why the rule lives in the
  # renderer and why half of these examples are about what must NOT match.
  describe "addresses" do
    def href(html)
      html[/href="([^"]+)"/, 1]
    end

    it "links the address out of a Time to go notice" do
      html = rendered["addr_time_to_go"]

      expect(html).to include(">11820 S State St Suite 320 Draper, UT, United States</a>")
      expect(href(html)).to start_with("https://maps.apple.com/?q=11820")
    end

    it "links the one in a Leave by notice too" do
      expect(rendered["addr_leave_by"]).to include("byte-md-map")
    end

    # Utah numbers its streets, so a great many real addresses carry no
    # street-type word at all - which is why the pattern can't require one.
    it "links a grid address with no street type in it" do
      expect(rendered["addr_grid_style"]).to include(">13389 S 5600 W, Herriman, UT 84096</a>")
    end

    it "takes a zip+4" do
      expect(rendered["addr_with_zip4"]).to include(">13401 Aintree Ave, Draper UT 84020-8887, United States</a>")
    end

    it "takes a city and state with no zip" do
      expect(rendered["addr_no_zip_comma_state"]).to include(">220 W 10600 S, Sandy UT 84070</a>")
    end

    it "takes one that opens the message" do
      expect(rendered["addr_at_start"]).to start_with("<a class=\"byte-md-link byte-md-map\"")
    end

    it "links one inside a table cell" do
      expect(rendered["addr_in_table"]).to include("<td><a class=\"byte-md-link byte-md-map\"")
    end

    it "carries a class of its own, so it can be told from an ordinary link" do
      expect(rendered["addr_at_start"]).to include("byte-md-link byte-md-map")
      expect(rendered["bare_url"]).not_to include("byte-md-map")
    end

    # Stashed first, so the address pass only ever sees a token.
    it "leaves an address that is already a link's text alone" do
      html = rendered["addr_as_link_text"]

      expect(href(html)).to eq("https://ardesian.com/x")
      expect(html).not_to include("maps.apple.com")
    end

    it "leaves one inside code untouched" do
      expect(rendered["addr_in_code_untouched"]).not_to include("<a")
    end

    # The span has to stop at a sentence boundary or it swallows the sentence
    # before it. Every token between the number and the state must start
    # uppercase, and "pm" does not.
    it "does not run a match across a full stop" do
      expect(rendered["addr_not_across_a_sentence"]).not_to include("<a")
    end

    # Without the state list, "in 20 minutes ... UT" is an address.
    it "does not treat a bare state mention as one" do
      expect(rendered["addr_state_alone_is_not_one"]).not_to include("<a")
    end

    it "wants a state, not just a street" do
      expect(rendered["addr_no_state_no_link"]).not_to include("<a")
    end

    it "links one in a receipt line as well" do
      expect(rendered["inline_address"]).to include(">220 W 10600 S, Sandy UT 84070</a>")
    end
  end
end
