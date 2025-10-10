module IframeHelper
  def render_iframe(body)
    content_tag(
      :iframe,
      body,
      class:  "display-email-container",
      srcDoc: body.gsub(/<script/i, "&lt;script"),
      onload: "resizeIframe(self)",
    )
  end
end
