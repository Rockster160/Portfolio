Buddy::Tools.register(
  name:        :request_feature,
  description: <<~TXT,
    Write down something you were asked for and CAN'T DO. Use it the moment you
    hit the edge of your tools.

    **CALLING IT IS THE OFFER.** It writes the row and leaves a receipt in one
    move, so you say "I can't do that one yet, so I've put it on the list" -
    past tense, because by then you have. Asked "can you order me a pizza?", a
    companion answered "I can't place the order from here, but I can put the
    idea on your list if you want" and called nothing: the offer was made, the
    row was not, and the person now has to ask a second time for the thing
    they'd already asked for. There is nothing here to get permission for.

    This is the honest answer, and it is a better one than either of the two
    you'd otherwise pick from. Saying no and stopping leaves them with nothing.
    Describing what they asked for as though you'd set it up is worse, and it
    is the easier mistake to make, because the words come out sounding like
    help: told to run a 30-minute rhythm with 10-minute breaks, one companion
    said the breaks were "lined up to pop in every half hour" and set a single
    countdown. Nothing was lined up. If you find yourself narrating an
    arrangement rather than making calls that build it, that is this tool.

    WHAT COUNTS: a thing your tools genuinely cannot express. A repeat nobody
    can set, a shape of reminder that doesn't exist, a screen you can't reach,
    a device that isn't wired. Check first - **your tool list is the authority
    on what you can do**, and most "I can't" turns out to be an argument you'd
    forgotten. A wrong "I can't" costs far more than a failed attempt.

    WHAT DOESN'T: something that simply isn't set up YET (an empty context
    section is not a missing feature, it's the thing they're asking you to
    fix), a job for a list, a thought for the stash, or anything you could do
    and would rather not.

    **"IT DIDN'T HAPPEN" IS NOT "IT DOESN'T EXIST."** When they report that
    something FAILED, they are telling you about a thing that already works.
    Filing that here converts a bug report into a wish: the list grows a row
    for a feature that shipped months ago, and the actual fault - the one they
    just handed you - goes unrecorded. It is the expensive direction of this
    mistake, because the row looks like diligence.

    So before writing down anything that sounds like it ought to be there
    already, **go and look: `jil_functions`, `jil_triggers`, and
    `read_listener_guide`.** Told that emptying a list hadn't triggered the
    house, a companion filed "trigger HASS when a list empties" - three tasks
    had been doing exactly that since August, and one way of removing an item
    out of four had quietly stopped calling them. If you find the thing, say
    you found it and that it didn't fire this time. That sentence is worth
    more than the row, and it is the only one that gets it fixed.

    TWO THAT LOOK LIKE WALLS AND AREN'T. Both have been filed as a feature
    request with the tool for it sitting in the list:

      - "check X every 30 minutes until it's done" - `set_timer` with
        `repeat: true`, and its `stop_when` family for the ending.
      - "tell me when someone's at the door" / any sensor, button, camera or
        door in the house - `remind_when` with `trigger: "custom"`. Call
        `read_listener_guide` and it will show you what's already reporting in.

    And one that looks like a wall and IS one: "let me know when <somebody
    else> gets home". `arrive` watches the person asking, never a third party,
    so this only works if something in the house reports her specifically.
    Read the listener guide first - if nothing does, this is exactly what this
    tool is for, and filing it is the right answer rather than a shortfall.

    **DO THE HALF YOU CAN.** Most walls are hit part of the way through
    something you can otherwise handle, and stopping at the wall leaves them
    with nothing when they could have had most of it. Make the calls for the
    part that works, write down the part that doesn't, and say which is which
    in one sentence: "I've set the 30-minute check-ins, and put the
    stop-when-it-finishes part on the list." Never offer them a choice between
    the request and the doable half - do the half.

    **WRITE DOWN THE PART THAT DOESN'T WORK, not the whole request.** If you
    can set a repeat but not its ending, the request is the ending. A row
    titled for the thing you could already do is worse than none: it reads as
    a missing feature that isn't missing, and the real gap goes unrecorded.
    `title` names that part in a handful of words.

    `body` is what they actually wanted, in enough of their own words that it
    still makes sense to somebody reading it next month with no memory of this
    conversation - the whole ask for context, then what you could and couldn't
    do about it.

    Asking for the same thing again adds to the one that's already written down
    rather than making a second; you'll be told when that happens, and it's
    worth saying, because "you've asked for that before" is a real answer.

    **"THAT'S NOT WHAT I MEANT" IS NOT A SECOND FILING.** When they tell you the
    row you just wrote is wrong, sending the same words again writes nothing at
    all - the merge sees text it already holds and there is no change to make.
    Prod 5420-5422: told "that's not what's needed at all", a companion said it
    had put the corrected request on the list and re-sent the identical body;
    the row's `updated_at` never moved. Say back what is actually written down
    and ask what it should say instead. Then file THAT - the part they say is
    missing, in the words they just used.
  TXT
  args:        {
    title: { type: :string, required: true, description: "A few words naming the thing they wanted" },
    body:  { type: :string, required: true, description: "What they asked for and what you couldn't do, in their words" },
  },
  confirm:     ->(payload, _ctx) {
    title = payload[:title].to_s.strip
    body  = payload[:body].to_s.strip
    raise "no feature to write down" if title.empty? || body.empty?

    { summary: "Write down: #{title}?", resolved: { title: title, body: body } }
  },
  label:       ->(payload, _ctx) { { title: "📮 #{payload[:title]}", sub: "feature request" } },
  merge_key:   ->(payload) { "request_feature:#{payload[:title].to_s.downcase.strip}" },
  supersedes:  true,
  # Level 1: writing something down hurts nobody, and a checkbox in front of it
  # turns a warm "want me to put that on the list?" into paperwork. It leaves a
  # receipt, and the receipt is the read-back.
  auto:        true,
  # The whole value is one particular thing somebody couldn't have. Replaying it
  # inside a routine would file the same gap over and over.
  routinable:  false,
  execute:     ->(payload, ctx) {
    title = payload[:title].to_s.strip.first(120)
    body  = payload[:body].to_s.strip.first(2000)

    # A second telling fills in what the first didn't carry rather than starting
    # a second row. Somebody who keeps hitting the same wall says so more than
    # once, and a list with the same gap on it four times is a list nobody reads.
    again = FeatureRequest.similar_to(ctx.user, title, body)
    if again
      merged = [again.body, body].uniq.join("\n\n").first(2000)
      added  = merged != again.body
      again.update!(body: merged) if added
      next {
        request_id: again.id,
        title:      again.title,
        again:      true,
        added:      added,
        # Nothing was written, and the receipt underneath says so - but the
        # sentence is written from here, before the receipt is read. Without
        # this the reply is "I've put the corrected request on the list" over a
        # row that never changed (prod 5420-5422).
        note:       (
          unless added
            "NOTHING WAS WRITTEN. That is word for word what is already on the list, so there was " \
              "no change to make. If they've just told you the row is wrong, read them what it " \
              "actually says and ask what it should say instead - don't report a fresh filing."
          end
        ),
      }.compact
    end

    request = FeatureRequest.create!(
      user:              ctx.user,
      byte_conversation: ctx.conversation,
      title:             title,
      body:              body,
    )
    Buddy::FeatureRequests.notify_owner!(request)

    {
      request_id: request.id,
      title:      request.title,
      revert:     { op: "created", model: "FeatureRequest", id: request.id, summary: "took it back off the list" },
    }
  },
  receipt:     ->(result, _ctx) {
    next "Already on the list, word for word: **#{result[:title]}** ✓" if result[:again] && !result[:added]
    next "Added that to **#{result[:title]}**, which was already on the list ✓" if result[:again]

    "On the list: **#{result[:title]}** ✓"
  },
)
