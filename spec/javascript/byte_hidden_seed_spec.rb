require "rails_helper"

# Hidden rows are the house's own scaffolding sitting in the thread: a trigger
# seed the reply hangs on, a quick-action post that gives the Mac somewhere to
# answer, the `/today` seed. They are real persisted messages, and their bodies
# open "[nothing was said to you - this fired on its own at 5:59pm]".
#
# Every path that mounts a bubble has to subtract them. Three of the four went
# through `upsertMessage`, which does. The fourth is scrollback, which builds its
# nodes directly so it can prepend a whole page in one insert and keep the scroll
# anchored - and it carried only the duplicate guard. So scrolling back through a
# busy week turned up seeds as bubbles the person appeared to have typed, roughly
# one in five in the main Buddy thread.
#
# The server drops them now too (ByteMessage.not_hidden, proven in
# byte_controller_spec). This is the client half, which still matters because the
# live socket delivers them regardless of what the history endpoint sends.
RSpec.describe "Byte hidden trigger seeds" do
  let(:src) { Rails.root.join("app/javascript/src/pages/byte/index.js").read }

  it "asks one predicate, not two hand-written checks" do
    expect(src).to include("function isHiddenMessage(message)")
    # The raw shape reads only inside the predicate. Anywhere else is a second
    # definition, which is how the two paths came apart in the first place.
    expect(src.scan(/metadata\?\.hidden/).length).to eq(1)
  end

  it "guards both paths that mount a node" do
    expect(src.scan(/isHiddenMessage\(/).length).to eq(3)
    expect(src).to match(/function upsertMessage\(message, opts = \{\}\) \{\n.*\n    if \(isHiddenMessage\(message\)\) \{/)
  end

  # The scrollback page is the one that regressed, so it is named rather than
  # counted: the drop has to happen before the node is built, inside the loop
  # over the fetched page.
  it "drops them before building the prepended page" do
    loader = src[/async function maybeLoadOlder\(\) \{(.*?)\n  \}/m, 1].to_s
    expect(loader).to include("if (isHiddenMessage(m)) return;")
    expect(loader.index("isHiddenMessage(m)")).to be < loader.index("newMessageNode()")
  end

  # A hidden row arriving live for something already on screen has to take the
  # node away, not merely skip mounting it - that is the quick-action trigger
  # whose optimistic bubble is already there.
  it "still removes a node when one is already mounted" do
    expect(src).to match(/if \(isHiddenMessage\(message\)\) \{\n\s+const existing = nodeForServerMessage\(message\);\n\s+if \(existing\) existing\.remove\(\);/)
  end
end
