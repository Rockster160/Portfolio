# == Schema Information
#
# Table name: error_reports
#
#  id          :bigint           not null, primary key
#  backtrace   :text
#  channel     :text
#  error_class :text
#  extra       :jsonb            not null
#  fingerprint :text             not null
#  message     :text
#  section     :text             not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint
#
class ErrorReport < ApplicationRecord
  # The day's failures, written down where they can be read back.
  #
  # Everything here already went to Slack. A channel is a fine place to be
  # interrupted and a terrible place to answer the question this is for - how
  # many times today, since when, and is it the same one - so the ping stays and
  # the row is what gets counted.
  #
  # Written from the two funnels that have an exception in hand:
  # Buddy::Errors.report, and SlackNotifier whenever it is called while one is
  # being handled. The informational Slack traffic - mail landing, an SMS
  # arriving - is not a failure and stays out.
  #
  # The row is written for EVERY occurrence; the ALERT is not. A repeat while
  # the same failure is still going is held back, because a channel filling up
  # with one incident is a channel nobody reads - see #announcement for when it
  # speaks again, which it always eventually does. Suppressed is never
  # swallowed: the count comes with it, and the rows were there all along.
  #
  # Nothing reads these at runtime. Three things read them afterwards, which is
  # the point of there being rows at all: `/system/errors`, the Daily Audit's
  # last section, and `.claude/prod-errors.sh`. Each alert carries a link to its
  # own row, so a Slack line ends at the whole failure rather than at as much of
  # it as fitted in a message.
  belongs_to :user, optional: true

  # Rows the UI pages through at a time.
  PAGE = 100

  # How far back the page looks when nothing says otherwise, and the windows it
  # offers.
  WINDOWS = [24, 24 * 7, 24 * 30].freeze
  DEFAULT_WINDOW = 24 * 7

  # Enough of the message to recognise it, short of pasting a page of SQL or an
  # HTTP body into every row.
  MESSAGE_LIMIT = 1_000

  # Where it was raised and how it got there. Past this the frames are rack and
  # the bottom of the stack, which are the same for everything.
  BACKTRACE_FRAMES = 12

  # Distinct failures a digest will name. A window with more kinds of error than
  # this in it has one real story and the report should be about that.
  DIGEST_LIMIT = 25

  # How long the same failure keeps being the SAME INCIDENT. A repeat inside
  # this is the thing still going on; past it, something started again, and
  # starting again is news.
  QUIET_BREAK = 30.minutes

  # ...and a failure that never stops is said again this often, carrying how
  # many have piled up since. The point of suppressing repeats is to stop the
  # channel filling with one incident, never to let a running fire go quiet.
  REANNOUNCE_AFTER = 2.hours

  scope :since, ->(time) { where(created_at: time..) }
  scope :recent, -> { order(created_at: :desc) }
  # Recorded and never announced anywhere, which makes it the kind nobody has
  # seen.
  # Failures nothing has EVER announced - which is not the same as an
  # occurrence that was suppressed as a repeat. `channel` is per occurrence, so
  # the question has to be asked of the whole fingerprint.
  scope :never_announced, -> { where.not(fingerprint: unscoped.where.not(channel: nil).select(:fingerprint)) }
  scope :for_section, ->(section) { where(section: section) }
  scope :for_class, ->(klass) { where(error_class: klass) }
  scope :like, ->(fingerprint) { where(fingerprint: fingerprint) }
  # `nil` is a real answer here - a failure with nobody attached to it - so a
  # blank is left alone rather than read as "any".
  scope :for_user, ->(id) { id.to_s == "none" ? where(user_id: nil) : where(user_id: id) }

  # Never raises and never blocks: the caller is already handling a failure, and
  # losing the record of one is better than turning it into two.
  #
  # `channel` means "this occurrence was announced somewhere". Both funnels
  # leave it alone here and stamp it with #announced! once the alert is actually
  # away, because whether one goes out is decided from the row's own history.
  def self.record!(section:, exception: nil, message: nil, user: nil, extra: {}, channel: nil)
    klass = exception&.class&.name
    text  = [message.presence, exception&.message.presence].compact.join("\n")

    create!(
      section:     section.to_s.presence || "unknown",
      error_class: klass,
      message:     text.truncate(MESSAGE_LIMIT).presence,
      backtrace:   Array(exception&.backtrace).first(BACKTRACE_FRAMES).join("\n").presence,
      fingerprint: fingerprint_for(section, klass, text),
      channel:     channel.presence,
      user_id:     user&.id,
      extra:       extra.presence || {},
    )
  rescue StandardError => e
    Rails.logger.error("[ErrorReport] couldn't record #{section}: #{e.class}: #{e.message}")
    nil
  end

  # Who it happened for, in a form that doesn't need looking up. An id on its
  # own answers a question nobody asked - it is the name that says whether a
  # failure matters and to whom. One definition, so the alert and the page name
  # the same person the same way.
  def self.who(user)
    return "nobody" if user.nil?

    "#{user.first_name} (##{user.id})"
  end

  def who
    return "user ##{user_id}" if user.nil? && user_id.present?

    self.class.who(user)
  end

  # Its own page, for an alert to point at. Answers nil rather than raising:
  # a link is worth having and never worth a second failure.
  def page_url
    Rails.application.routes.url_helpers.system_error_url(id: id)
  rescue StandardError
    nil
  end

  # Whether this occurrence is worth saying out loud, and what to say with it.
  # nil means stay quiet: the same failure is already announced and still
  # going, and a channel filling up with one incident is a channel nobody
  # reads. The record keeps every occurrence either way.
  #
  #   :new      - nothing like it on file, or nothing like it ever announced
  #   :back     - it had stopped for a while and has started again
  #   :ongoing  - it never stopped, and it has been long enough to say so again
  def announcement
    siblings = self.class.like(fingerprint).where.not(id: id)
    previous = siblings.maximum(:created_at)
    return { reason: :new } if previous.nil?

    quiet_for = created_at - previous
    return { reason: :back, quiet_for: quiet_for } if quiet_for > QUIET_BREAK

    announced_at = siblings.where.not(channel: nil).maximum(:created_at)
    return { reason: :new } if announced_at.nil?

    running_for = created_at - announced_at
    return nil if running_for < REANNOUNCE_AFTER

    {
      reason:      :ongoing,
      running_for: running_for,
      # The ones that were held back, plus this one. Suppressed is not swallowed
      # - the count is how they all reach him at once.
      count:       siblings.where(created_at: announced_at..).count + 1,
    }
  end

  # Stamped once the alert is away, which is what makes `channel` the answer to
  # "was this occurrence announced" - and so what the suppression above reads.
  # Two processes raising the same brand-new failure in the same instant can
  # both decide to announce; one duplicate alert for a first occurrence is a
  # better trade than a lock on an error path.
  def announced!(channel)
    update!(channel: channel)
  rescue StandardError
    nil
  end

  # A repeat has to say what it is or it reads as news. Phrased relatively,
  # because what an alert about a repeat is answering is "how long has this
  # been going on".
  def self.repeat_note(announcement)
    case announcement[:reason]
    when :back
      "_back after #{in_words(announcement[:quiet_for])} quiet_"
    when :ongoing
      running = in_words(announcement[:running_for])
      "_still going - #{announcement[:count]} of these in the #{running} since the last alert_"
    end
  end

  def self.in_words(seconds)
    ActionController::Base.helpers.distance_of_time_in_words(seconds.to_i)
  end

  # Slack's own link syntax, or just the row number where no URL can be built.
  def slack_ref
    url = page_url
    url.blank? ? "error ##{id}" : "<#{url}|error ##{id}>"
  end

  # The same failure has to fingerprint the same on every occurrence, so the
  # parts that move between them come out: the record ids, the timestamps, the
  # hex in an object inspection, the line numbers in a quoted path.
  def self.fingerprint_for(section, error_class, message)
    stable = message.to_s.gsub(/0x[0-9a-f]+/i, "0xX").gsub(/\d+/, "N")
    Digest::SHA256.hexdigest([section, error_class, stable.truncate(300)].join("|"))[0, 16]
  end

  # One entry per distinct failure in the span, the most repeated first, each
  # carrying a real row to read the detail off. Grouped in SQL: a window with a
  # loop in it can hold thousands of rows, and none of them is worth loading to
  # count the others.
  #
  # `scope:` is for a caller that has already narrowed it - the page's filters -
  # and it replaces the window rather than adding to it, so the span it is
  # passed has to be the same one.
  def self.digest(span, limit: DIGEST_LIMIT, scope: nil)
    grouped = (scope || where(created_at: span)).group(:fingerprint).pluck(
      Arel.sql("COUNT(*), MIN(created_at), MAX(created_at), MAX(id), COUNT(channel)"),
    )
    top     = grouped.sort_by { |count, _first, last, _id, _sent| [-count, -last.to_i] }.first(limit)
    samples = where(id: top.pluck(3)).index_by(&:id)

    top.filter_map { |count, first_at, last_at, id, announced|
      row = samples[id]
      next if row.nil?

      {
        section:     row.section,
        error_class: row.error_class,
        message:     row.message,
        fingerprint: row.fingerprint,
        # Of the GROUP, not of the newest occurrence: repeats are deliberately
        # suppressed, so the latest row of a long-running failure is normally
        # unannounced while the failure itself was announced long ago.
        announced:   announced.positive?,
        user_id:     row.user_id,
        count:       count,
        first_at:    first_at,
        last_at:     last_at,
        sample_id:   id,
      }
    }
  end
end
