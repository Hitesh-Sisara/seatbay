import { IconDownload, IconGitHub, IconMenu } from "./Icons";
import { nav, site } from "@/lib/site";

export function Brand() {
  return (
    <a href="/" className="brand" aria-label="Seatbay home">
      <img src="/seatbay-mark.svg" alt="" width="46" height="21" className="brand-mark" />
      <span className="brand-word">Seatbay</span>
    </a>
  );
}

export function Header() {
  return (
    <header className="header">
      <div className="wrap header-inner">
        <Brand />
        <nav className="nav" aria-label="Main">
          {nav.map((item) => (
            <a key={item.href} href={item.href}>
              {item.label}
            </a>
          ))}
        </nav>
        <div className="header-actions">
          <a className="icon-link" href={site.repo} aria-label="Seatbay on GitHub">
            <IconGitHub />
          </a>
          <a className="btn btn-light btn-sm header-download" href={site.download}>
            <IconDownload className="btn-icon" />
            Download
          </a>
          {/* Mobile menu: a native <details>, so it works without JavaScript. */}
          <details className="menu">
            <summary className="icon-link" aria-label="Menu">
              <IconMenu />
            </summary>
            <div className="menu-panel">
              {nav.map((item) => (
                <a key={item.href} href={item.href}>
                  {item.label}
                </a>
              ))}
              <a href={site.repo}>GitHub</a>
              <a className="btn btn-light" href={site.download}>
                <IconDownload className="btn-icon" />
                Download for macOS
              </a>
            </div>
          </details>
        </div>
      </div>
    </header>
  );
}
