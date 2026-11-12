// Asks the real reload preflight about the answers a server gives while it
// boots, and prints each verdict as JSON for reload_preflight_spec.rb.
const { pageReady, SHELL_MARKER } = await import(
  "../../app/javascript/src/pages/byte/reload_preflight.js"
);

const answer = (status, body) => async () => ({
  ok: status >= 200 && status < 300,
  status,
  text: async () => body,
});

const shell = `<html><head>${SHELL_MARKER}</head><body></body></html>`;
const out = {
  shell:         await pageReady("/board/1?_bust=x", answer(200, shell)),
  bad_gateway:   await pageReady("/board/1?_bust=x", answer(502, "<h1>502 Bad Gateway</h1>")),
  error_page:    await pageReady("/board/1?_bust=x", answer(500, shell)),
  login_page:    await pageReady("/board/1?_bust=x", answer(200, "<form>Sign in</form>")),
  refused:       await pageReady("/board/1?_bust=x", async () => {
    throw new TypeError("Failed to fetch");
  }),
};

process.stdout.write(JSON.stringify(out, null, 2));
