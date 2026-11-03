require "rails_helper"

# Badges hang `position: absolute` off `position: relative` header buttons. A
# press reset that sets `position` on `button:active` outranks every anchor, so
# the badge resolves against the whole app the moment it is touched. That is a
# fact about the resolved cascade, not about any one rule.

# Each one an element to resolve against: what it is, and everything above it.
anchors = {
  "the unread count on the hamburger"     => {
    own:       "byte-drawer-toggle",
    ancestors: %w[ctr-byte byte-app byte-header],
  },
  "the update badge on the reload button" => {
    own:       "byte-reload-btn",
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

  # The press nudge is a `translate`, which moves only the paint, and the reset
  # cancels exactly that. Neither may set `top` or `position`: a nudge that did
  # made a fixed button `relative` under the finger, and a reset that did took
  # away the `top` it hangs from - either way it jumped and the release missed.
  it "nudges and cancels a press without touching any button's positioning" do
    reset = CompiledCss.rules.find { |rule|
      rule["selector"].split(",").map(&:strip).include?(".ctr-byte .byte-app button:active")
    }

    expect(reset).not_to be_nil, "the app-wide press reset is gone entirely"
    expect(reset["body"].scan(/([a-z-]+):/).flatten).to eq(["translate"])

    nudge = Rails.root.join("app/assets/stylesheets/components/forms.scss").read[/&:active \{[^}]*translate[^}]*\}/]
    expect(nudge).to be_present, "the app-wide press nudge isn't a translate"
    expect(nudge).not_to match(/\b(?:top|position):/)
  end
end
