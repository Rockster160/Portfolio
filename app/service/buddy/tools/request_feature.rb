Buddy::Tools.register(
  name:        :request_feature,
  description: <<~TXT,
    Write down something you were asked for and CAN'T DO. Use it the moment you
    hit the edge of your tools, and offer it out loud: "I can't do that one yet
    - want me to put it on the list?"

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
      again.update!(body: [again.body, body].uniq.join("\n\n").first(2000))
      next { request_id: again.id, title: again.title, again: true }
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
    next "Added that to **#{result[:title]}**, which was already on the list ✓" if result[:again]

    "On the list: **#{result[:title]}** ✓"
  },
)
