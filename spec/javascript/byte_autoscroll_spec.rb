require "rails_helper"

# The thread scrolls itself for exactly one reason: something new arrived while
# the person was already at the bottom. Anything else is the thread moving under
# somebody who was reading, and it has now been reported three times.
#
# The last one: scrolled up to this morning's briefing, clicked the message to
# select the words, and got thrown to the bottom. The cause was
# `composerFocused()` used as a REASON TO SCROLL. It is a state, not a moment -
# type a message, then scroll up, and the composer still holds focus, so every
# resize and every mutation re-pinned. On iOS visualViewport fires a scroll
# event as you scroll, which re-measures the app height, which re-pinned again.
#
# Reaching for the composer is NOT a request to go anywhere either: people type
# from something further up, answering it or copying pieces of several messages
# into one reply. Sending is the gesture that means the bottom. The one thing
# focus still does is hold a reader who was ALREADY at the bottom in place while
# the mobile keyboard shoves the viewport around.
RSpec.describe "Byte thread auto-scroll" do
  let(:src) { Rails.root.join("app/javascript/src/pages/byte/index.js").read }

  # Lines that actually move the thread, comments excluded.
  def scrolling_lines
    src.lines.each_with_index.filter_map { |line, i|
      next if line.strip.start_with?("//")
      next unless line.include?("scrollToBottom(") || line.include?("thread.scrollTop = thread.scrollHeight")

      [i + 1, line.strip]
    }
  end

  it "never moves the thread because the composer happens to hold focus" do
    offenders = scrolling_lines.select { |_, line| line.include?("composerFocused()") }

    expect(offenders).to be_empty,
      "these scroll on composer focus, which outlives the gesture and drags a " \
      "reader back down: #{offenders.inspect}"
  end

  it "keeps the keyboard pin as a bounded moment" do
    expect(src).to include("composePinUntil = Date.now() + COMPOSE_PIN_MS")
    expect(src).to match(/const COMPOSE_PIN_MS = \d+;/)
    expect(src).to include("const pinningToCompose = () => Date.now() < composePinUntil")
  end

  # The correction: tapping the composer while reading something further up used
  # to travel to the bottom. It holds a position now, and only one already held.
  it "does not move a reader who reaches for the composer part way up" do
    expect(src).to include("if (!composerFocused() || !measureAtBottom()) return;")
  end

  # The other half of the rule: what a reader who is NOT at the bottom gets
  # instead of being moved.
  it "counts what arrived instead of scrolling to it" do
    expect(src).to include("unreadCount += 1")
    expect(src).to include("jumpCount.textContent = unreadCount > 0")
  end

  # The same test the drawer badge uses, so the two numbers mean one thing: a
  # receipt chip and a half-streamed reply are not something to come back to.
  it "counts the same things the drawer counts" do
    expect(src).to include("if (!countsAsUnread(message)) return;")
  end
end
