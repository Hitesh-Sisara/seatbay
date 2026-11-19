import { Brand } from "./Header";
import { disclaimer, site } from "@/lib/site";

export function Footer() {
  return (
    <footer className="footer">
      <div className="wrap">
        <div className="footer-grid">
          <div className="footer-about">
            <Brand />
            <p>
              Run several Claude Desktop apps on one Mac, each with its own account or API key and its own numbered Dock
              icon. Free and open source.
            </p>
          </div>
          <nav aria-label="Product">
            <p className="footer-h">Product</p>
            <ul>
              <li>
                <a href="/#features">Features</a>
              </li>
              <li>
                <a href="/#how-it-works">How it works</a>
              </li>
              <li>
                <a href="/#install">Install</a>
              </li>
              <li>
                <a href="/#faq">FAQ</a>
              </li>
            </ul>
          </nav>
          <nav aria-label="Documentation">
            <p className="footer-h">Docs</p>
            <ul>
              <li>
                <a href="/docs#install">Getting started</a>
              </li>
              <li>
                <a href="/docs#api-instances">API instances</a>
              </li>
              <li>
                <a href="/docs#backups">Backups and S3</a>
              </li>
              <li>
                <a href="/docs#command-line">Command line</a>
              </li>
            </ul>
          </nav>
          <nav aria-label="Project">
            <p className="footer-h">Project</p>
            <ul>
              <li>
                <a href={site.repo}>GitHub</a>
              </li>
              <li>
                <a href={site.releases}>Releases</a>
              </li>
              <li>
                <a href={site.issues}>Report an issue</a>
              </li>
              <li>
                <a href={site.license}>MIT licence</a>
              </li>
              <li>
                <a href="/privacy">Privacy</a>
              </li>
            </ul>
          </nav>
        </div>
        <div className="footer-legal">
          <p>{disclaimer}</p>
          <p>
            © 2026{" "}
            <a href={site.author.url} rel="author">
              {site.author.name}
            </a>
            . Seatbay is released under the MIT licence. No cookies, no analytics.
          </p>
        </div>
      </div>
    </footer>
  );
}
