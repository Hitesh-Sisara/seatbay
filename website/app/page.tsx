import type { ReactNode } from "react";
import { Code } from "@/components/Code";
import { JsonLd } from "@/components/JsonLd";
import { DockScene, Tile } from "@/components/Scene";
import {
  IconArchive,
  IconArrow,
  IconBadge,
  IconBolt,
  IconCheck,
  IconCloud,
  IconDash,
  IconDownload,
  IconGitHub,
  IconKey,
  IconLock,
  IconMacs,
  IconMoon,
  IconPulse,
  IconRefresh,
  IconSeats,
  IconShield,
  IconSignIn,
  IconTerminal,
} from "@/components/Icons";
import { faq, faqText } from "@/lib/content";
import { faqLd, pageMeta, softwareLd, sourceCodeLd } from "@/lib/seo";
import { disclaimer, site } from "@/lib/site";

export const metadata = pageMeta({
  path: "/",
  title: "Seatbay: run multiple Claude Desktop accounts on your Mac",
  absoluteTitle: true,
  description:
    "Run multiple Claude Desktop instances on macOS, each signed in to its own account or API key gateway, with its own numbered Dock icon. Free and open source.",
});

type Feature = { icon: ReactNode; tone: string; title: string; body: ReactNode };

const features: Feature[] = [
  {
    icon: <IconSeats />,
    tone: "violet",
    title: "One Claude per account",
    body: "Each instance keeps its own sign-in, chats, settings, MCP servers and Claude Code sessions in its own data folder. Run them all at once, next to your regular Claude.",
  },
  {
    icon: <IconBadge />,
    tone: "blue",
    title: "A Dock icon you can tell apart",
    body: "Pick a colour and a number, add a label strip such as WORK, and API instances get an API tag. The regular Claude icon still opens your main Claude.",
  },
  {
    icon: <IconSignIn />,
    tone: "green",
    title: "Sign in without quitting",
    body: (
      <>
        Google and email sign-in end with a <code>claude://</code> link. Seatbay hands it to the instance that asked,
        so the others keep running.
      </>
    ),
  },
  {
    icon: <IconKey />,
    tone: "amber",
    title: "API keys and gateways",
    body: "Connect an instance to an Anthropic API key or any Anthropic-compatible gateway, with custom models and headers. Test Connection costs no tokens.",
  },
  {
    icon: <IconArchive />,
    tone: "violet",
    title: "Backups that run themselves",
    body: "On quit, and every night between 2 and 3 AM, open instances included. Optional encrypted upload to S3, R2, B2, Wasabi or MinIO.",
  },
  {
    icon: <IconShield />,
    tone: "blue",
    title: "Safe updates",
    body: "Opt in, and Seatbay checks that the downloaded Claude update is signed by Anthropic, backs everything up, runs Claude's own installer and reopens what was open. Roll Back if needed.",
  },
  {
    icon: <IconPulse />,
    tone: "green",
    title: "Health at a glance",
    body: "Every Claude with its state, memory, CPU, process count, sign-in and version, so you can see which one is heavy or needs a restart.",
  },
  {
    icon: <IconMoon />,
    tone: "amber",
    title: "Sleep idle instances",
    body: "Optionally quit instances that sat idle in the background for 30 minutes, after a backup. Working instances are never put to sleep.",
  },
  {
    icon: <IconMacs />,
    tone: "violet",
    title: "Your second Mac, too",
    body: "Install Seatbay on another Mac over SSH and copy your profiles there: names, colours, numbers and labels. Sign-ins stay on the Mac they belong to.",
  },
];

const extras: { icon: ReactNode; title: string; body: ReactNode }[] = [
  {
    icon: <IconBolt />,
    title: "Bypass permissions by default",
    body: (
      <>
        One switch sets <code>permissions.defaultMode</code> in <code>~/.claude/settings.json</code>, so new Claude Code
        sessions start in Bypass permissions in every Claude, and in the <code>claude</code> CLI.
      </>
    ),
  },
  {
    icon: <IconTerminal />,
    title: "A full command line",
    body: (
      <>
        Create instances, check health, back up, restore, configure S3 and API instances, and run safe updates from
        scripts. See the <a href="/docs#command-line">reference</a>.
      </>
    ),
  },
  {
    icon: <IconLock />,
    title: "Private by design",
    body: "No telemetry, no analytics, no account. Nothing leaves your Mac except backups you send to your own bucket.",
  },
];

function Check({ children }: { children: ReactNode }) {
  return (
    <span className="cmp-yes">
      <IconCheck className="cmp-icon" />
      {children}
    </span>
  );
}

function No({ children }: { children: ReactNode }) {
  return (
    <span className="cmp-no">
      <IconDash className="cmp-icon" />
      {children}
    </span>
  );
}

export default function Home() {
  return (
    <>
      <JsonLd data={softwareLd} />
      <JsonLd data={sourceCodeLd} />
      <JsonLd data={faqLd(faqText)} />

      {/* Hero */}
      <section className="hero" aria-labelledby="hero-title">
        <div className="hero-bg" aria-hidden="true" />
        <div className="wrap hero-inner">
          <p className="pill">
            <span className="pill-dot" aria-hidden="true" />
            Free and open source · macOS 14+ · Formerly Multi Claude
          </p>
          <h1 id="hero-title">
            Every Claude account,
            <br />
            <span className="grad">its own seat in the Dock.</span>
          </h1>
          <p className="lede hero-lede">
            Seatbay runs several Claude Desktop apps on one Mac at the same time. Each one is signed in to a different
            Claude account, or connected to an API key or gateway, and has its own coloured, numbered Dock icon.
          </p>
          <div className="btn-row hero-cta">
            <a className="btn btn-light btn-lg" href={site.download}>
              <IconDownload className="btn-icon" />
              Download for macOS
            </a>
            <a className="btn btn-ghost btn-lg" href={site.repo}>
              <IconGitHub className="btn-icon" />
              View on GitHub
            </a>
          </div>
          <p className="hero-meta">
            <span>MIT licence</span>
            <span>Apple silicon and Intel</span>
            <span>Needs Claude Desktop</span>
            <a href={site.releases}>All releases</a>
          </p>
          <DockScene />
        </div>
      </section>

      {/* Promise strip */}
      <section className="strip" aria-label="Promises">
        <div className="wrap strip-inner">
          <p>
            <IconShield className="strip-icon" />
            <span>
              <strong>Claude.app is never modified.</strong> Instances run from a private clone.
            </span>
          </p>
          <p>
            <IconLock className="strip-icon" />
            <span>
              <strong>No telemetry, no account.</strong> Your data stays on your Mac.
            </span>
          </p>
          <p>
            <IconRefresh className="strip-icon" />
            <span>
              <strong>Always the installed version.</strong> Instances follow Claude's own updates.
            </span>
          </p>
        </div>
      </section>

      {/* Features */}
      <section className="section" id="features" aria-labelledby="features-title">
        <div className="wrap">
          <header className="section-head">
            <p className="eyebrow">Features</p>
            <h2 id="features-title">Multiple Claude Desktop accounts, without the juggling</h2>
            <p className="lede">
              Stop signing out and back in. Give your personal account, your work account and your API key each a
              Claude of their own, and switch between them from the Dock.
            </p>
          </header>
          <ul className="feature-grid">
            {features.map((f) => (
              <li key={f.title} className="card feature">
                <span className={`feature-icon tone-${f.tone}`}>{f.icon}</span>
                <h3>{f.title}</h3>
                <p>{f.body}</p>
              </li>
            ))}
          </ul>
          <ul className="extras">
            {extras.map((f) => (
              <li key={f.title}>
                <span className="extras-icon">{f.icon}</span>
                <div>
                  <h3>{f.title}</h3>
                  <p>{f.body}</p>
                </div>
              </li>
            ))}
          </ul>
        </div>
      </section>

      {/* How it works */}
      <section className="section section-soft" id="how-it-works" aria-labelledby="how-title">
        <div className="wrap">
          <header className="section-head">
            <p className="eyebrow">How it works</p>
            <h2 id="how-title">A tiny app per instance, a private clone of Claude</h2>
            <p className="lede">
              Seatbay doesn't patch Claude. Each instance is a small app it generates in <code>~/Applications</code>,
              and opening it starts Claude from a fresh APFS clone with its own data folder.
            </p>
          </header>

          <div className="flow" role="group" aria-label="Diagram: how an instance starts">
            <div className="flow-source">
              <span className="flow-kicker">Installed app</span>
              <code>/Applications/Claude.app</code>
              <span className="flow-note">Never modified</span>
            </div>
            <div className="flow-drop" aria-hidden="true">
              <span>APFS clone on every launch · 0.2 s · no extra disk space</span>
            </div>
            <div className="flow-node flow-a">
              <Tile n={2} color="blue" label="WORK" className="tile-sm" />
              <span className="flow-kicker">1 · You open</span>
              <code>~/Applications/Claude Work.app</code>
              <span className="flow-note">About 200 KB: its own name, bundle id and icon, plus a small launcher.</span>
            </div>
            <div className="flow-arrow flow-arrow-1" aria-hidden="true">
              <IconArrow />
            </div>
            <div className="flow-node flow-node-main">
              <span className="flow-kicker">2 · It runs from</span>
              <code>…/Seatbay/Runtime.noindex/&lt;id&gt;/Claude Work.app</code>
              <span className="flow-note">
                A private copy, so macOS treats it as its own app. Never patched or re-signed, so the code signature
                and keychain access stay Claude's.
              </span>
            </div>
            <div className="flow-arrow flow-arrow-2" aria-hidden="true">
              <IconArrow />
            </div>
            <div className="flow-node flow-c">
              <span className="flow-kicker">3 · With its own data</span>
              <code>--user-data-dir=…/Instances/&lt;id&gt;</code>
              <span className="flow-note">Sign-in, cookies, settings, MCP servers, Cowork and Code sessions, all kept apart.</span>
            </div>
          </div>

          <ul className="how-grid">
            <li>
              <h3>Why a copy at all?</h3>
              <p>
                macOS tells running apps apart by the path they run from. If every instance ran{" "}
                <code>/Applications/Claude.app</code>, clicking the regular Claude icon could bring an instance forward
                instead of your main Claude.
              </p>
            </li>
            <li>
              <h3>Cleans up after itself</h3>
              <p>
                When an instance quits, a helper deletes its copy and leaves a link in its place, so a path the Dock
                remembered still opens the instance.
              </p>
            </li>
            <li>
              <h3>No duplicates</h3>
              <p>
                Opening an instance that's already running just brings its window forward. Seatbay finds it by its data
                folder in the process table.
              </p>
            </li>
            <li>
              <h3>Your main Claude is untouched</h3>
              <p>
                It keeps using <code>~/Library/Application Support/Claude</code>. Seatbay never changes that folder; it
                only reads it to back it up.
              </p>
            </li>
          </ul>
        </div>
      </section>

      {/* API instances */}
      <section className="section" id="api" aria-labelledby="api-title">
        <div className="wrap split">
          <div className="split-copy">
            <p className="eyebrow">API instances</p>
            <h2 id="api-title">Claude Desktop with an API key or any gateway</h2>
            <p className="lede">
              Claude Desktop can run on an API key instead of a Claude account. Seatbay sets that up per instance, so
              one Dock icon can be your subscription and the next your team's gateway.
            </p>
            <ul className="ticks">
              <li>
                <IconCheck className="tick" />
                <span>
                  <strong>Anthropic's API</strong> with a blank Base URL, or <strong>any Anthropic-compatible gateway</strong>.
                </span>
              </li>
              <li>
                <IconCheck className="tick" />
                <span>
                  Key sent as <code>x-api-key</code> or <code>Authorization: Bearer</code>, plus your model list and extra
                  headers.
                </span>
              </li>
              <li>
                <IconCheck className="tick" />
                <span>
                  <strong>Test Connection</strong> asks for the model list, so it costs no tokens.
                </span>
              </li>
              <li>
                <IconCheck className="tick" />
                <span>Claude seals the key with the macOS keychain the first time the instance starts.</span>
              </li>
              <li>
                <IconCheck className="tick" />
                <span>Switch an instance between account and API key at any time; both setups are kept.</span>
              </li>
            </ul>
            <p>
              <a className="text-link" href="/docs#api-instances">
                Set up an API instance <IconArrow className="inline-arrow" />
              </a>
            </p>
          </div>
          <div className="split-visual">
            <div className="sheet" role="img" aria-label="Illustration of the API connection form: Connect with API key, a gateway base URL, the key sent as Authorization Bearer, two model ids, and a successful Test Connection that used no tokens.">
              <div className="sheet-head" aria-hidden="true">
                <Tile n={4} color="amber" api className="tile-sm" />
                <div>
                  <p className="sheet-title">Claude Gateway</p>
                  <p className="sheet-sub">Edit instance</p>
                </div>
              </div>
              <div className="sheet-body" aria-hidden="true">
                <div className="field">
                  <span className="field-label">Connect with</span>
                  <span className="seg">
                    <span>Claude account</span>
                    <span className="on">API key</span>
                  </span>
                </div>
                <div className="field">
                  <span className="field-label">Base URL</span>
                  <span className="input">https://gateway.example.com/anthropic</span>
                </div>
                <div className="field">
                  <span className="field-label">API key</span>
                  <span className="input input-secret">••••••••••••••••••••</span>
                </div>
                <div className="field">
                  <span className="field-label">Send key as</span>
                  <span className="seg">
                    <span>x-api-key</span>
                    <span className="on">Bearer</span>
                  </span>
                </div>
                <div className="field">
                  <span className="field-label">Models</span>
                  <span className="input">
                    <span className="tag">model-large</span> <span className="tag">model-fast</span>
                  </span>
                </div>
                <div className="sheet-foot">
                  <span className="btn-fake">Test Connection</span>
                  <span className="ok">
                    <IconCheck className="ok-icon" /> Connected · 2 models · 0 tokens
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Backups */}
      <section className="section section-soft" id="backups" aria-labelledby="backups-title">
        <div className="wrap">
          <header className="section-head">
            <p className="eyebrow">Backups</p>
            <h2 id="backups-title">Back up Claude Desktop without thinking about it</h2>
            <p className="lede">
              A backup holds a Claude's sign-in, settings and local session data, without caches and downloads. Seatbay
              takes them for your main Claude and every instance.
            </p>
          </header>
          <div className="backup-grid">
            <ol className="timeline">
              <li>
                <span className="tl-when">On quit</span>
                <p>
                  Each time a Claude quits (at most once every 6 hours each), while it's closed: the cleanest kind of
                  backup.
                </p>
              </li>
              <li>
                <span className="tl-when">Every night, 2–3 AM</span>
                <p>
                  Once you turn it on, every Claude that changed is backed up, open ones too: its folder is cloned in a
                  fraction of a second and the clone is archived, so nothing is closed. You pick the hour.
                </p>
              </li>
              <li>
                <span className="tl-when">Catch-up</span>
                <p>
                  Asleep or offline at night? The round runs once the Mac is awake and retries every 30 minutes until it
                  succeeds. A launchd agent runs it, so Seatbay doesn't need to be open.
                </p>
              </li>
              <li>
                <span className="tl-when">Restore</span>
                <p>
                  Pick a backup to restore. The current folder is backed up first and moved to the Trash, so a restore can
                  be undone. Or restore a backup as a new instance.
                </p>
              </li>
            </ol>
            <div className="card vault">
              <span className="feature-icon tone-violet">
                <IconCloud />
              </span>
              <h3>Encrypted copies in your own bucket</h3>
              <p>
                Optionally upload every backup to S3-compatible storage. It's encrypted on your Mac with{" "}
                <strong>AES-256-GCM</strong> before it leaves, with a key derived from your passphrase
                (PBKDF2-HMAC-SHA256, 600,000 rounds, a random salt per file). Restore it on another Mac with the same
                passphrase.
              </p>
              <ul className="chips" aria-label="Supported storage">
                <li>AWS S3</li>
                <li>Cloudflare R2</li>
                <li>Backblaze B2</li>
                <li>Wasabi</li>
                <li>MinIO</li>
              </ul>
              <p className="muted small">
                Backups are usually a few MB, and the last 10 per Claude stay on your Mac. A backup contains sign-in
                data, so treat the folder and the bucket like passwords.
              </p>
              <a className="text-link" href="/docs#backups">
                Set up S3 or R2 <IconArrow className="inline-arrow" />
              </a>
            </div>
          </div>
        </div>
      </section>

      {/* open -n comparison */}
      <section className="section" id="why-not-open-n" aria-labelledby="compare-title">
        <div className="wrap">
          <header className="section-head">
            <p className="eyebrow">Compared</p>
            <h2 id="compare-title">
              Why not just <code>open -n</code>?
            </h2>
            <p className="lede">
              You can start a second Claude with its own data folder in one line. It works, until you need to tell the
              windows apart, sign in, or click the Claude icon.
            </p>
          </header>
          <Code code={`open -n -a Claude --args --user-data-dir="$HOME/claude-work"`} label="The one-liner" />
          <div className="table-wrap">
            <table className="cmp">
              <caption className="sr-only">The open -n one-liner compared with Seatbay</caption>
              <thead>
                <tr>
                  <th scope="col">
                    <span className="sr-only">Capability</span>
                  </th>
                  <th scope="col">
                    <code>open -n</code> one-liner
                  </th>
                  <th scope="col">Seatbay</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <th scope="row">Separate sign-in, chats and settings</th>
                  <td>
                    <Check>Yes</Check>
                  </td>
                  <td>
                    <Check>Yes</Check>
                  </td>
                </tr>
                <tr>
                  <th scope="row">Tell instances apart in the Dock</th>
                  <td>
                    <No>Every copy shows the same icon</No>
                  </td>
                  <td>
                    <Check>Colour, number, label and API tag</Check>
                  </td>
                </tr>
                <tr>
                  <th scope="row">Regular Claude icon opens your main Claude</th>
                  <td>
                    <No>Not reliably: they all run from the same path</No>
                  </td>
                  <td>
                    <Check>Each instance runs from its own clone</Check>
                  </td>
                </tr>
                <tr>
                  <th scope="row">Google or email sign-in</th>
                  <td>
                    <No>The claude:// link goes to your main Claude</No>
                  </td>
                  <td>
                    <Check>Routed to the instance that asked</Check>
                  </td>
                </tr>
                <tr>
                  <th scope="row">Open from Spotlight, Raycast, Alfred or the Dock</th>
                  <td>
                    <No>A Terminal command or script</No>
                  </td>
                  <td>
                    <Check>A real app in ~/Applications</Check>
                  </td>
                </tr>
                <tr>
                  <th scope="row">Backups, safe updates, health</th>
                  <td>
                    <No>Up to you</No>
                  </td>
                  <td>
                    <Check>Built in</Check>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      {/* Install */}
      <section className="section section-soft" id="install" aria-labelledby="install-title">
        <div className="wrap">
          <header className="section-head">
            <p className="eyebrow">Install</p>
            <h2 id="install-title">Up and running in a minute</h2>
            <p className="lede">
              You need macOS 14 or later, on Apple silicon or Intel, and Claude Desktop in <code>/Applications</code>.
            </p>
          </header>
          <ol className="steps">
            <li className="card step">
              <span className="step-n">1</span>
              <h3>Download</h3>
              <p>
                Download <a href={site.download}>Seatbay.zip</a> from the{" "}
                <a href={site.releases}>latest release</a>, unzip it and move <strong>Seatbay.app</strong> to your
                Applications folder.
              </p>
              <a className="btn btn-primary btn-sm" href={site.download}>
                <IconDownload className="btn-icon" />
                Seatbay.zip
              </a>
            </li>
            <li className="card step">
              <span className="step-n">2</span>
              <h3>Open it the first time</h3>
              <p>
                Seatbay is ad-hoc signed, not notarized, so macOS blocks a plain double-click the first time.{" "}
                <strong>Control-click (or right-click) Seatbay → Open</strong>, then click Open.
              </p>
              <p className="muted small">
                No Open button on newer macOS? Go to System Settings → Privacy &amp; Security and click{" "}
                <strong>Open Anyway</strong>. Or run <code>xattr -dr com.apple.quarantine /Applications/Seatbay.app</code>.
              </p>
            </li>
            <li className="card step">
              <span className="step-n">3</span>
              <h3>Create an instance</h3>
              <p>
                Click <strong>New Instance</strong>, choose a name, number, colour and optional label, then{" "}
                <strong>Create</strong>. Open it and sign in with <strong>Sign In…</strong>.
              </p>
            </li>
          </ol>
          <div className="source">
            <div>
              <h3>Build from source</h3>
              <p>
                Needs Xcode 16 or later, or its command-line tools with Swift 5.10+. The build script builds and
                ad-hoc signs <code>Seatbay.app</code>; <code>--install</code> also copies it to{" "}
                <code>~/Applications</code>.
              </p>
            </div>
            <Code
              code={`git clone ${site.repo}.git
cd seatbay
./scripts/build.sh --install   # build, sign, copy to ~/Applications`}
            />
          </div>
        </div>
      </section>

      {/* FAQ */}
      <section className="section" id="faq" aria-labelledby="faq-title">
        <div className="wrap faq-wrap">
          <header className="section-head">
            <p className="eyebrow">FAQ</p>
            <h2 id="faq-title">Questions</h2>
          </header>
          <div className="faq">
            {faq.map((item) => (
              <details key={item.q}>
                <summary>
                  <h3>{item.q}</h3>
                </summary>
                <div className="faq-a">
                  {item.a.map((p, i) => (
                    <p key={i}>{p}</p>
                  ))}
                </div>
              </details>
            ))}
          </div>
        </div>
      </section>

      {/* CTA */}
      <section className="cta" aria-labelledby="cta-title">
        <div className="hero-bg" aria-hidden="true" />
        <div className="wrap cta-inner">
          <div className="cta-tiles" aria-hidden="true">
            <Tile n={1} color="violet" />
            <Tile n={2} color="blue" label="WORK" />
            <Tile n={3} color="green" />
          </div>
          <h2 id="cta-title">Give every account its own seat.</h2>
          <p className="lede">Free, MIT licensed, no account and no telemetry.</p>
          <div className="btn-row">
            <a className="btn btn-light btn-lg" href={site.download}>
              <IconDownload className="btn-icon" />
              Download for macOS
            </a>
            <a className="btn btn-ghost btn-lg" href="/docs">
              Read the docs
              <IconArrow className="btn-icon" />
            </a>
          </div>
          <p className="cta-fine">{disclaimer}</p>
        </div>
      </section>
    </>
  );
}
