require "rails_helper"

# The list view paints a paperclip off `has_attachments`, and opening the
# message showed the words only - `to_html` is the body, and a file that arrived
# with the mail has no URL anywhere. It exists inside the message and nowhere
# else, so nothing but this reaches it.
RSpec.describe "Email attachments", type: :request do
  let(:user) { create(:user, role: :admin) }

  # A PDF the mail was sent to deliver and a one-pixel PNG in the signature,
  # which between them are nearly all of the real traffic.
  let(:pdf) { "%PDF-1.4 interview guide" }
  let(:ics) { "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Screening\nEND:VEVENT\nEND:VCALENDAR" }
  let(:png_b64) {
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
  }

  # The real shape, which is the part that matters: the words are a
  # multipart/alternative NESTED inside a multipart/mixed, and the files sit
  # beside that branch rather than next to the text.
  def rfc822(with_attachments: true)
    files = [
      "--mixed42",
      "Content-Type: application/pdf; name=\"Interview_Guide.pdf\"",
      "Content-Disposition: attachment; filename=\"Interview_Guide.pdf\"",
      "Content-Transfer-Encoding: base64",
      "",
      Base64.strict_encode64(pdf),
      "--mixed42",
      "Content-Type: image/png; name=\"logo.png\"",
      "Content-Disposition: attachment; filename=\"logo.png\"",
      "Content-Transfer-Encoding: base64",
      "",
      png_b64,
      "--mixed42",
      "Content-Type: text/calendar; charset=UTF-8; name=\"invite.ics\"",
      "Content-Disposition: attachment; filename=\"invite.ics\"",
      "",
      ics,
    ]

    [
      "Date: Mon, 6 Oct 2026 16:45:57 -0600",
      "Subject: Your recruiter screening is set!",
      "From: no-reply@gh-mail.example.com",
      "To: #{user.email}",
      "Message-ID: <attach-#{SecureRandom.hex(4)}@example.com>",
      "MIME-Version: 1.0",
      "Content-Type: multipart/mixed; boundary=\"mixed42\"",
      "",
      "--mixed42",
      "Content-Type: multipart/alternative; boundary=\"alt42\"",
      "",
      "--alt42",
      "Content-Type: text/plain; charset=UTF-8",
      "",
      "Your screening is set.",
      "--alt42",
      "Content-Type: text/html; charset=UTF-8",
      "",
      "<p>Your screening is set.</p>",
      "--alt42--",
      *(files if with_attachments),
      "--mixed42--",
      "",
    ].compact.join("\n")
  end

  def store(**opts)
    Emails::StoreRaw.call(user: user, raw: rfc822(**opts), direction: :inbound)
  end

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  describe "GET /emails/:id" do
    it "lists every file the message came with" do
      email = store

      get email_path(email)

      expect(response.body).to include("3 attachments")
      expect(response.body).to include("Interview_Guide.pdf")
      expect(response.body).to include("logo.png")
      expect(response.body).to include("invite.ics")
      expect(response.body).to include(attachment_email_path(email, 0))
    end

    it "says nothing at all when the message came with none" do
      email = store(with_attachments: false)

      get email_path(email)

      expect(response.body).not_to include("email-attachments")
    end
  end

  describe "GET /emails/:id/attachments/:index" do
    it "hands over the file itself" do
      email = store

      get attachment_email_path(email, 0)

      expect(response.body).to eq(pdf)
      expect(response.headers["Content-Type"]).to include("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("Interview_Guide.pdf")
    end

    # Anything the browser can draw opens where it was asked for. Everything
    # else downloads - a calendar invite in particular, which is only any use
    # once it reaches the calendar.
    it "opens what the browser can draw and downloads what it cannot" do
      email = store

      get attachment_email_path(email, 0)
      expect(response.headers["Content-Disposition"]).to start_with("inline")

      get attachment_email_path(email, 1)
      expect(response.headers["Content-Disposition"]).to start_with("inline")
      expect(response.body.bytesize).to eq(Base64.decode64(png_b64).bytesize)

      get attachment_email_path(email, 2)
      expect(response.headers["Content-Disposition"]).to start_with("attachment")
      expect(response.body).to eq(ics)
    end

    it "says so rather than erroring for a position that isn't there" do
      email = store

      get attachment_email_path(email, 7)

      expect(response).to redirect_to(email_path(email))
      expect(flash[:alert]).to include("isn't on this message")
    end

    # Ruby reads a negative index from the END of the array, so a hand-typed
    # -1 would hand over the last file rather than nothing.
    it "refuses a negative position" do
      email = store

      get attachment_email_path(email, -1)

      expect(response).to redirect_to(email_path(email))
    end

    it "is nobody else's to read" do
      other = create(:user, role: :admin)
      theirs = Emails::StoreRaw.call(user: other, raw: rfc822, direction: :inbound)

      get attachment_email_path(theirs, 0)

      # ApplicationController rescues RecordNotFound into a redirect, so the
      # thing worth pinning is that the bytes do not come back.
      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include("interview guide")
    end
  end
end
