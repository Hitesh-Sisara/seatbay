import { JsonLd } from "@/components/JsonLd";
import { breadcrumbLd, pageMeta } from "@/lib/seo";
import { site } from "@/lib/site";

export const metadata = pageMeta({
  path: "/privacy",
  title: "Privacy",
  description:
    "Seatbay collects nothing: no telemetry, no analytics, no account. This website sets no cookies and runs no analytics or third-party scripts.",
});

export default function PrivacyPage() {
  return (
    <>
      <JsonLd
        data={breadcrumbLd([
          { name: "Home", path: "/" },
          { name: "Privacy", path: "/privacy" },
        ])}
      />
      <section className="page-hero">
        <div className="hero-bg" aria-hidden="true" />
        <div className="wrap">
          <nav aria-label="Breadcrumb" className="crumbs">
            <ol>
              <li>
                <a href="/">Home</a>
              </li>
              <li aria-current="page">Privacy</li>
            </ol>
          </nav>
          <h1>Privacy</h1>
          <p className="lede">Short version: Seatbay collects nothing, and neither does this website.</p>
        </div>
      </section>
      <section className="section-tight">
        <div className="wrap prose narrow">
          <h2 id="app">The Seatbay app</h2>
          <ul>
            <li>No telemetry, no analytics, no crash reporting and no account.</li>
            <li>
              Everything Seatbay knows (your instances, settings and backups) stays in files on your Mac, under{" "}
              <code>~/Library/Application Support/Seatbay</code>.
            </li>
            <li>
              Seatbay sends data only where you tell it to: backups to the S3-compatible bucket you configure (encrypted on
              your Mac first), and profiles (names, colours, numbers, labels) to your own second Mac over SSH.
            </li>
            <li>
              Each Claude instance talks to Anthropic, or to the API gateway you set for it, exactly as Claude Desktop does
              on its own. Those connections are between Claude and that service; Seatbay doesn't see or log them.
            </li>
            <li>
              The source code is public on <a href={site.repo}>GitHub</a>, so you can check all of this.
            </li>
          </ul>

          <h2 id="website">This website</h2>
          <ul>
            <li>No cookies, no analytics, no tracking pixels and no third-party scripts or fonts.</li>
            <li>
              It's a static site served by Cloudflare. Like any web host, Cloudflare processes standard request data (such
              as IP addresses) to deliver and protect the site; we don't collect or keep it.
            </li>
            <li>
              The download link goes to GitHub Releases, which is covered by GitHub's own privacy statement.
            </li>
          </ul>

          <h2 id="contact">Contact</h2>
          <p>
            Questions? Open an issue on <a href={site.issues}>GitHub</a> or reach{" "}
            <a href={site.author.url}>{site.author.name}</a>.
          </p>
          <p className="muted small">Last updated 19 November 2026.</p>
        </div>
      </section>
    </>
  );
}
