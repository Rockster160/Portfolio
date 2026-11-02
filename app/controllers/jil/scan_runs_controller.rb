# A task's run-on-scan link, /r/KEY: opening it is the press.
#
# The GET only renders. The run is a POST the page's own script sends once the
# page is actually on screen, so anything that fetches the link without a
# person looking at it (link previews, crawlers, prefetch, a prerender, a
# background tab) gets a page and nothing runs.
#
# Every GET hands the page a single-use pass, and the page swaps its URL for
# one carrying that pass before it runs. A reload, or a tab the browser
# restores later, lands on the pass URL, and that URL never runs by itself:
# only a fresh open of /r/KEY does.
class Jil::ScanRunsController < ApplicationController
  PASS_TTL = 10.minutes

  before_action :authorize_user
  before_action :set_task
  before_action { no_store }

  def show
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    return head(:no_content) if prefetch?

    @state = (
      if @task.needs_inputs?
        :inputs
      elsif params[:once].present?
        spent?(params[:once]) ? :ran : :idle
      else
        :run
      end
    )
    @pass = issue_pass if @state == :run

    render layout: false
  end

  def create
    return head(:unprocessable_entity) if @task.needs_inputs?

    nonce = pass_nonce(params[:once])
    return head(:gone) if nonce.nil?
    return head(:conflict) unless spend!(nonce)

    ::Jil::Executor.async_call(
      @task.user, @task.code, { execute: true }, task: @task, auth: :run, auth_id: current_user.id
    )
    head :ok
  end

  private

  def set_task
    @task = current_user.accessible_tasks.from_key(params[:id])
  end

  # Chrome, Firefox and Safari all mark speculative loads. Answering them with
  # nothing keeps them from being kept and shown later as if it were a visit.
  def prefetch?
    purpose = [request.headers["Sec-Purpose"], request.headers["Purpose"], request.headers["X-Moz"]]
    purpose.compact.any? { |value| value.include?("prefetch") || value.include?("prerender") }
  end

  def issue_pass
    verifier.generate([@task.id, SecureRandom.urlsafe_base64(12)], expires_in: PASS_TTL)
  end

  def pass_nonce(pass)
    task_id, nonce = verifier.verified(pass.to_s)
    nonce if task_id == @task.id
  end

  def spent?(pass)
    nonce = pass_nonce(pass)
    nonce.present? && Rails.cache.exist?(spent_key(nonce))
  end

  # Atomic, so the same pass can never run twice.
  def spend!(nonce)
    Rails.cache.write(spent_key(nonce), true, unless_exist: true, expires_in: PASS_TTL)
  end

  def spent_key(nonce)
    "jil_scan_run:#{nonce}"
  end

  def verifier
    @verifier ||= ActiveSupport::MessageVerifier.new(
      Rails.application.key_generator.generate_key("jil_scan_run"),
      url_safe: true,
    )
  end
end
