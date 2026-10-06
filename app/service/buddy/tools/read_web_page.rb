# The page's own words, in the same turn, so the thing it gets used for is
# built out of facts rather than out of the link's spelling. See Buddy::WebPage
# for what is fetched and what is refused.
Buddy::Tools.register(
  name:        :read_web_page,
  description: <<~TXT,
    Open a link and read the page, then answer from what is actually on it.

    **A link is not a page.** The words in a URL are a guess: the slug names
    something, a date in the path is often only one of several the page lists,
    and the address of the place is never in there at all. So whenever a message
    carries a link and what they want depends on what is on it, read it FIRST
    and do the rest afterwards - both in the same turn, without asking.

    That is the shape of "we're going to this" with a link under it: read the
    page, work out which of the dates on it is the one they mean, and put that
    date, that time and that address on the calendar. A name lifted off the URL
    and a place nobody read is an appointment somewhere they aren't going.

    Reach for it the same way for a job posting they want tracked, an article
    they want the gist of, a recipe, or anything they ask you to go check on a
    page.

    What comes back is the page's text, and it arrives before you write your
    reply, so speak from it: the part they asked about, in your own words,
    short. Don't paste the page back at them. Where the page is SILENT, say so
    and ask - a gap filled from your own guess is the failure this tool exists
    to stop, and it reads exactly like a fact.

    Public pages only. Anything behind a login, a file on a machine here, or an
    address on this network won't open, and this says which. Pass that on
    plainly; never describe a page you didn't get.

    A link into this app is not a page to read: a job row, a piece of mail, an
    agenda item. Those are records, each reachable with the tool that owns it,
    and fetching one gets the sign-in page instead.
  TXT
  args:        {
    url: { type: :string, required: true, description: "The full http(s) link to open" },
  },
  # A read of something public, and nothing is written: no row to tap, and
  # nothing worth asking permission for.
  auto:        true,
  answers:     true,
  # The refusals belong here rather than in `execute`: this is where the model
  # is asking, and a raise here comes back as a sentence it can read out.
  confirm:     ->(payload, _ctx) {
    uri = Buddy::WebPage.checked_uri(payload[:url])
    { summary: "Read #{uri.host}", resolved: { url: uri.to_s, host: uri.host } }
  },
  label:       ->(payload, _ctx) { { title: "🔗 #{payload[:host] || payload["host"]}", sub: "reading the page" } },
  execute:     ->(payload, _ctx) {
    page = Buddy::WebPage.read(payload[:url])

    page.merge(
      how: "This is the page itself. Answer from these words only - if what they asked " \
           "about isn't in here, say it isn't on the page.",
    )
  },
)
