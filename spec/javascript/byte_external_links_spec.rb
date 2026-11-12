require "rails_helper"

# Byte is a home-screen app scoped to the whole site, so a link followed in
# place replaces the conversation. Every web link is sent out of the app:
# Safari on iOS standalone, a new tab anywhere else.
RSpec.describe "Byte external links" do
  let(:result) {
    module_path = Rails.root.join("app/javascript/src/pages/byte/external_links.js")
    JsRunner.eval_module(
      <<~JS,
        import { outsideHref, openOutside, initExternalLinks } from "#{module_path}";

        function fakeWindow({ standalone } = {}) {
          const win = {
            navigator: standalone === undefined ? {} : { standalone },
            location: { href: "https://ardesian.com/byte" },
            opened: [],
            open(url, target, features) { win.opened.push([url, target, features]); },
          };
          return win;
        }

        function link(href, attrs = {}) {
          const a = {
            href: new URL(href, "https://ardesian.com/byte").href,
            getAttribute: (name) => (name === "href" ? href : attrs[name] ?? null),
            hasAttribute: (name) => name in attrs,
          };
          a.closest = (sel) => (sel === "a[href]" ? a : null);
          return a;
        }

        function click(target, extra = {}) {
          const event = {
            target,
            button: 0,
            defaultPrevented: false,
            preventDefault() { event.defaultPrevented = true; },
            ...extra,
          };
          return event;
        }

        function tap(win, target, extra) {
          let listener;
          initExternalLinks({ addEventListener: (_type, fn) => { listener = fn; } }, win);
          const event = click(target, extra);
          listener(event);
          return { prevented: event.defaultPrevented, opened: win.opened, location: win.location.href };
        }

        const desktop = () => fakeWindow();
        const iphone = () => fakeWindow({ standalone: true });

        console.log(JSON.stringify({
          href: {
            web:        outsideHref("https://example.com/a?b=1"),
            same_site:  outsideHref("/buddy/activities", { base: "https://ardesian.com/byte" }),
            ios:        outsideHref("https://example.com/a", { iosStandalone: true }),
            ios_http:   outsideHref("http://example.com/a", { iosStandalone: true }),
            mailto:     outsideHref("mailto:a@b.c"),
            tel:        outsideHref("tel:555"),
            javascript: outsideHref("javascript:alert(1)"),
            garbage:    outsideHref("::::"),
          },
          open: {
            desktop: (() => { const w = desktop(); openOutside("https://example.com", w); return w.opened; })(),
            iphone:  (() => { const w = iphone(); openOutside("/custom_charts/4", w); return [w.opened, w.location.href]; })(),
            mailto:  (() => { const w = desktop(); return [openOutside("mailto:a@b.c", w), w.opened]; })(),
          },
          tap: {
            same_site_desktop: tap(desktop(), link("/buddy/activities")),
            same_site_iphone:  tap(iphone(), link("/buddy/activities")),
            off_site_iphone:   tap(iphone(), link("https://maps.apple.com/?q=x", { target: "_blank" })),
            download:          tap(iphone(), link("/files/a.pdf", { download: "" })),
            hash:              tap(iphone(), link("#top")),
            mailto:            tap(iphone(), link("mailto:a@b.c")),
            already_handled:   tap(desktop(), link("/x"), { defaultPrevented: true }),
            middle_click:      tap(desktop(), link("/x"), { button: 1 }),
            not_a_link:        tap(desktop(), { closest: () => null }),
          },
        }));
      JS
    )
  }

  describe "where a link is sent" do
    it "keeps a web link as it is outside iOS" do
      expect(result["href"]["web"]).to eq("https://example.com/a?b=1")
      expect(result["href"]["same_site"]).to eq("https://ardesian.com/buddy/activities")
    end

    it "hands it to Safari on an iOS home-screen app" do
      expect(result["href"]["ios"]).to eq("x-safari-https://example.com/a")
      expect(result["href"]["ios_http"]).to eq("x-safari-http://example.com/a")
    end

    it "leaves anything that isn't a web link alone" do
      expect(result["href"].values_at("mailto", "tel", "javascript", "garbage")).to all(be_nil)
    end
  end

  describe "opening" do
    it "opens a new tab outside iOS" do
      expect(result["open"]["desktop"]).to eq([["https://example.com/", "_blank", "noopener"]])
    end

    it "sends the iPhone app to Safari, absolute, without opening a window" do
      opened, location = result["open"]["iphone"]
      expect(opened).to eq([])
      expect(location).to eq("x-safari-https://ardesian.com/custom_charts/4")
    end

    it "does nothing for a non-web link" do
      expect(result["open"]["mailto"]).to eq([false, []])
    end
  end

  describe "a tap anywhere in Byte" do
    it "opens one of this site's pages in a new tab instead of in place" do
      tap = result["tap"]["same_site_desktop"]
      expect(tap["prevented"]).to be(true)
      expect(tap["opened"]).to eq([["https://ardesian.com/buddy/activities", "_blank", "noopener"]])
    end

    it "sends one of this site's pages to Safari from the iPhone app" do
      tap = result["tap"]["same_site_iphone"]
      expect(tap["prevented"]).to be(true)
      expect(tap["location"]).to eq("x-safari-https://ardesian.com/buddy/activities")
    end

    it "sends an outside link to Safari too, target or not" do
      expect(result["tap"]["off_site_iphone"]["location"]).to eq("x-safari-https://maps.apple.com/?q=x")
    end

    it "leaves downloads, page anchors and mailto links to the browser" do
      result["tap"].values_at("download", "hash", "mailto").each { |tap|
        expect(tap["prevented"]).to be(false)
        expect(tap["location"]).to eq("https://ardesian.com/byte")
      }
    end

    it "leaves a click another handler already took, a middle click, and a non-link" do
      result["tap"].values_at("already_handled", "middle_click", "not_a_link").each { |tap|
        expect(tap["opened"]).to eq([])
      }
      expect(result["tap"]["middle_click"]["prevented"]).to be(false)
    end
  end
end
