require "rails_helper"

# The reminder editor paints one modal for every kind of row: a one-off, a
# repeat, a hand-written watch, a named-trigger watch. Each paint function only
# sets what APPLIES, so anything that doesn't apply keeps whatever the last row
# left in it — prod: opening a deploy watch straight after a custom one showed
# the custom one's listener under "Fires when".
#
# `resetFields` is what makes the form a function of the row alone, and it only
# works if it knows about every field. That's the bit that rots: adding a
# control to the markup and forgetting the reset list is invisible until two
# rows of different shapes get opened back to back.
#
# So this reads both files and checks they still agree. No DOM, no browser —
# the failure mode is a missing NAME, which is a text comparison.
RSpec.describe "Buddy reminder editor field reset" do
  let(:markup_path) { Rails.root.join("app/views/byte/show.html.erb") }
  let(:script_path) { Rails.root.join("app/javascript/src/pages/byte/buddy/reminders.js") }

  # Painted unconditionally on open, or structural (a button, a static label),
  # so they can't carry a stale value between rows. Plus the selects whose
  # value paintRepeat/paintMonthly set whenever the block they live in is
  # visible, and which are read back only when that same block applies.
  let(:safe_to_skip) {
    %w[title preview-title preview-body summary when-label] +
      %w[cancel save] +
      %w[freq unit monthmode setpos]
  }

  def editor_markup
    html = markup_path.read
    html[html.index("data-byte-reminder-edit")...html.index("data-byte-settings-modal")]
  end

  def declared_fields
    editor_markup.scan(/data-byte-edit-([a-z-]+)/).flatten.uniq.sort
  end

  def reset_list(constant)
    body = script_path.read[/#{constant} = \[(.*?)\]/m, 1].to_s
    body.scan(/"([a-z-]+)"/).flatten
  end

  def reset_fields
    reset_list("VALUE_FIELDS") + reset_list("TOGGLE_FIELDS")
  end

  it "clears or deliberately skips every field in the editor" do
    missing = declared_fields - reset_fields - safe_to_skip

    expect(missing).to be_empty, <<~MSG
      These editor fields are neither reset nor listed as safe to skip:
        #{missing.join(", ")}
      Add them to VALUE_FIELDS / TOGGLE_FIELDS in reminders.js, or to the
      skip lists here if they really are painted on every open.
    MSG
  end

  it "does not reset a field the markup no longer has" do
    stale = reset_fields - declared_fields

    expect(stale).to be_empty, "reminders.js resets fields that aren't there: #{stale.join(", ")}"
  end

  # The bug underneath the stale listener: an author `display` beats the
  # `hidden` attribute's UA rule, so a flex container stays on screen when JS
  # hides it. Every container the editor toggles needs its own guard.
  it "guards each toggled container against the display/hidden trap" do
    css = Rails.root.join("app/assets/stylesheets/pages/byte.scss").read

    %w[byte-edit-row byte-edit-repeat byte-edit-days byte-modal-label].each do |klass|
      guarded = css.include?(".#{klass}[hidden]") || rule_block(css, klass).include?("&[hidden]")

      expect(guarded).to be(true),
        ".#{klass} sets a display, so the `hidden` attribute won't hide it. " \
        "Add `&[hidden] { display: none; }` inside it or a `.#{klass}[hidden]` rule."
    end
  end

  # The class's own declarations, brace-matched. A plain regex runs past the
  # closing brace and finds an `&[hidden]` belonging to something else.
  def rule_block(css, klass)
    start = css.index(/^\.#{Regexp.escape(klass)}\s*\{/)
    return "" if start.nil?

    depth = 0
    css[start..].each_char.with_index do |char, offset|
      depth += 1 if char == "{"
      next unless char == "}"

      depth -= 1
      return css[start, offset + 1] if depth.zero?
    end
    ""
  end
end
