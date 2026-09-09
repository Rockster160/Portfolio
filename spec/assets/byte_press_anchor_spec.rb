require "rails_helper"

# Two things in the header flew across the screen the moment you touched them:
# the unread count jumped from the hamburger's corner to the top-right of the
# app, and the diagonal slash over the notifications bell stretched into a line
# running corner to corner.
#
# Both are `position: absolute` off their button, and both buttons are
# `position: relative` so they can be. The press reset at the top of byte.scss
# said `position: static` — meant to undo the app-wide
# `button:active { position: relative; top: 1px }` nudge from forms.scss, and
# undoing the positioning along with it. At `.ctr-byte .byte-app button:active`
# it clocks (0,3,1), which outranks every anchor in the sheet, so pressing one
# handed its contents to `.byte-header` instead and they resolved against the
# whole app.
#
# That's a fact about the resolved cascade rather than about any declaration on
# its own, which is why it's asserted here: reading the anchor's own rule says
# `position: relative` and tells you nothing about what happens under a finger.

# Each one an element to resolve against: what it is, and everything above it.
anchors = {
  "the unread count on the hamburger"       => {
    own:       "byte-drawer-toggle",
    ancestors: %w[ctr-byte byte-app byte-header],
  },
  "the slash across the notifications bell" => {
    own:       "byte-notify-toggle",
    ancestors: %w[ctr-byte byte-app byte-header],
  },
}.freeze

RSpec.describe "Byte pressed-button anchors" do
  # Class bucket counts pseudo-classes and attribute selectors; `:active` is
  # why the reset outranked a same-class-count anchor.
  def specificity(selector)
    bare = selector.gsub(/::[a-z-]+/, "")

    [
      bare.scan(/#[\w-]+/).length,
      bare.scan(/\.[\w-]+/).length + bare.scan(/:[a-z-]+(\([^)]*\))?/).length +
        bare.scan(/\[[^\]]*\]/).length,
      bare.scan(/(?:\A|[\s>+~])([a-z][\w-]*)/).length,
    ]
  end

  # Does this selector apply to that anchor, pressed?
  #
  # Every class it names has to be one the element or something above it
  # carries, and its last compound has to land on the button itself rather than
  # on something inside it — which is what keeps the badge's own rule out of
  # the answer for the button.
  def applies?(selector, anchor)
    return false if selector.include?("::")

    known = anchor[:ancestors] + [anchor[:own]]
    return false unless selector.scan(/\.([\w-]+)/).flatten.all? { |c| known.include?(c) }
    return false unless selector.scan(/:([a-z-]+)/).flatten.all? { |p| p == "active" }

    final = selector.split(/[\s>+~]+/).last
    return false unless final.scan(/\.([\w-]+)/).flatten.all? { |c| c == anchor[:own] }

    final.scan(/(?:\A|[\s>+~])([a-z][\w-]*)/).flatten.all? { |tag| tag == "button" }
  end

  # Every `position` this anchor could take while pressed, in cascade order:
  # specificity, then document order. The last one is what the browser paints.
  def positions_for(anchor)
    CompiledCss.rules.each_with_index.flat_map { |rule, index|
      value = rule["body"][/(?:\A|[;{]\s*)position:\s*([^;]+)/, 1]
      next [] if value.nil? || rule["conditions"].present?

      rule["selector"].split(",").map(&:strip).filter_map { |selector|
        next unless applies?(selector, anchor)

        { selector: selector, value: value.strip, order: [specificity(selector), index] }
      }
    }.sort_by { |hit| hit[:order] }
  end

  anchors.each do |what, anchor|
    describe what do
      let(:winner) { positions_for(anchor).last }

      it "is still a containing block while it is being pressed" do
        expect(winner).not_to be_nil, "nothing positions .#{anchor[:own]} at all"
        expect(winner[:value]).not_to eq("static"),
          "`#{winner[:selector]}` wins and drops .#{anchor[:own]} out of position — " \
          "whatever it anchors resolves against .byte-header instead"
      end
    end
  end

  # The reset's whole job is to cancel the app-wide press nudge, and the nudge
  # is one pixel of `top`. Anything else it touches, it touches for every
  # button in the app at a specificity almost nothing can answer.
  it "cancels the press nudge without reaching past the offset" do
    reset = CompiledCss.rules.find { |rule|
      rule["selector"].split(",").map(&:strip).include?(".ctr-byte .byte-app button:active")
    }

    expect(reset).not_to be_nil, "the app-wide press reset is gone entirely"
    expect(reset["body"]).to include("top: auto")

    declared = reset["body"].scan(/([a-z-]+):/).flatten
    expect(declared).to eq(["top"])
  end
end
