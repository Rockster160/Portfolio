// Whether the page a reload is about to navigate to would come back as the
// real shell. A server mid-boot answers with a 502 or an error page, and a
// navigation lands on whatever it's given - so the URL is fetched first, and
// only a response carrying the shell's own marker counts. A redirect to the
// login page, a proxy's error page and a dropped connection all read as "not
// yet". The URL must be one the service worker doesn't answer from its cache
// (the reload's cache-busted one is), or this would only ever see the old
// shell and call it ready.
export const SHELL_MARKER = '<meta name="byte-shell" content="ok">';

export async function pageReady(url, fetchFn = fetch) {
  try {
    const res = await fetchFn(url, {
      credentials: "same-origin",
      cache: "no-store",
      headers: { Accept: "text/html" },
    });
    if (!res.ok) return false;
    return (await res.text()).includes(SHELL_MARKER);
  } catch (_) {
    return false;
  }
}
