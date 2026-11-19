import { Code } from "@/components/Code";
import { JsonLd } from "@/components/JsonLd";
import { cli, colours } from "@/lib/content";
import { breadcrumbLd, pageMeta } from "@/lib/seo";
import { site } from "@/lib/site";

export const metadata = pageMeta({
  path: "/docs",
  title: "Docs: install Seatbay and run multiple Claude Desktop instances",
  description:
    "How to install Seatbay and run multiple Claude Desktop instances: sign-in, API keys and gateways, encrypted S3/R2 backups, safe updates and the command line.",
});

const toc = [
  { id: "install", label: "Install" },
  { id: "create-instances", label: "Create instances" },
  { id: "sign-in", label: "Sign in" },
  { id: "api-instances", label: "API instances" },
  { id: "backups", label: "Backups and S3" },
  { id: "nightly-schedule", label: "Nightly schedule" },
  { id: "safe-updates", label: "Safe updates" },
  { id: "health-and-sleep", label: "Health and sleep" },
  { id: "other-mac", label: "Another Mac" },
  { id: "bypass-permissions", label: "Bypass permissions" },
  { id: "command-line", label: "Command line" },
  { id: "files", label: "Files and folders" },
  { id: "uninstall", label: "Uninstall" },
  { id: "troubleshooting", label: "Troubleshooting" },
];

const S = `S=${site.binary}`;

const files: [string, string][] = [
  ["~/Applications/<Name>.app", "The instance apps."],
  ["~/Library/Application Support/Seatbay/Instances/<id>", "Each instance's data: sign-in, chats, settings. API instances use <id>-3p."],
  ["~/Library/Application Support/Seatbay/Runtime.noindex", "The running instances' copies of Claude, and the links left after they quit."],
  ["~/Library/Application Support/Seatbay/Snapshots", "Local backups (the last 10 per Claude)."],
  ["~/Library/Application Support/Seatbay/PreviousClaude.noindex", "The Claude version kept for Roll Back."],
  ["~/Library/Application Support/Seatbay/settings.json, instances.json", "Preferences and the instance list."],
  ["~/Library/Application Support/Seatbay/secrets.json", "S3 keys and the backup passphrase (mode 0600)."],
  ["~/Library/Application Support/Seatbay/nightly-backup.json", "The last nightly round and its result."],
  ["~/Library/Application Support/Seatbay/Logs/launcher.log", "Launch and clean-up notes."],
  ["~/Library/Application Support/Seatbay/Logs/backup.log", "Backup rounds."],
  ["~/Library/LaunchAgents/in.sisara.seatbay.backup.plist", "The launchd agent that runs the nightly backup."],
];

export default function DocsPage() {
  return (
    <>
      <JsonLd
        data={breadcrumbLd([
          { name: "Home", path: "/" },
          { name: "Docs", path: "/docs" },
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
              <li aria-current="page">Docs</li>
            </ol>
          </nav>
          <h1>Seatbay documentation</h1>
          <p className="lede">
            Everything about running multiple Claude Desktop instances on your Mac: installing Seatbay, creating and
            signing in instances, API keys and gateways, backups to S3 or R2, updates, and the command line.
          </p>
        </div>
      </section>

      <div className="wrap docs">
        <aside className="docs-toc">
          <nav aria-label="On this page">
            <p className="toc-h">On this page</p>
            <ol>
              {toc.map((t) => (
                <li key={t.id}>
                  <a href={`#${t.id}`}>{t.label}</a>
                </li>
              ))}
            </ol>
          </nav>
        </aside>

        <article className="prose docs-body">
          {/* Install */}
          <section aria-labelledby="install">
            <h2 id="install">Install</h2>
            <h3 id="requirements">Requirements</h3>
            <ul>
              <li>macOS 14 Sonoma or later, on Apple silicon or Intel.</li>
              <li>
                Claude Desktop installed in <code>/Applications</code> (download it from{" "}
                <a href="https://claude.ai/download">claude.ai/download</a>).
              </li>
              <li>
                Claude.app and your home folder on the same APFS volume (the normal setup), so instances can run from an
                instant clone.
              </li>
            </ul>

            <h3 id="download">Download</h3>
            <ol>
              <li>
                Download <a href={site.download}>Seatbay.zip</a> from the{" "}
                <a href={site.releases}>releases page</a>.
              </li>
              <li>
                Unzip it and move <strong>Seatbay.app</strong> to <code>/Applications</code>. The nightly backup agent
                only installs when Seatbay runs from an Applications folder.
              </li>
            </ol>
            <p>
              To check the download, compare the output of <code>shasum -a 256 Seatbay.zip</code> with{" "}
              <code>Seatbay.zip.sha256</code> on the release page.
            </p>

            <h3 id="first-open">First open</h3>
            <p>
              Seatbay is ad-hoc signed and not notarized by Apple, so macOS refuses a plain double-click the first time.
              Control-click (or right-click) <strong>Seatbay</strong> in Applications, choose <strong>Open</strong>, then
              click <strong>Open</strong> in the dialog. If your macOS version shows no Open button, open{" "}
              <strong>System Settings → Privacy &amp; Security</strong>, scroll to the message about Seatbay and click{" "}
              <strong>Open Anyway</strong>. You only do this once per download. In Terminal, this does the same:
            </p>
            <Code code={`xattr -dr com.apple.quarantine /Applications/Seatbay.app`} />

            <h3 id="build-from-source">Build from source</h3>
            <p>You need Xcode 16 or later, or its command-line tools with Swift 5.10+.</p>
            <Code
              code={`git clone ${site.repo}.git
cd seatbay
./scripts/build.sh --install   # build, sign, copy to ~/Applications
swift test                     # run the unit tests`}
            />
            <p>
              To update Seatbay, download the new release (or pull and build again) and replace Seatbay.app. Seatbay
              rebuilds the instance apps after it is updated, so macOS may ask for some privacy permissions again.
            </p>

            <h3 id="upgrading-from-multi-claude">Upgrading from Multi Claude</h3>
            <p>
              Seatbay was called Multi Claude before its first public release. Installs from that time keep their data in{" "}
              <code>~/Library/Application Support/MultiClaude</code>. Seatbay finds it, rebuilds the instance apps with the
              new launcher, replaces the old backup agent and keeps uploading to the same S3 folder. Delete the old{" "}
              <code>Multi Claude.app</code> after installing Seatbay.
            </p>
          </section>

          {/* Create */}
          <section aria-labelledby="create-instances">
            <h2 id="create-instances">Create instances</h2>
            <p>
              Open Seatbay and click <strong>New Instance</strong>. Choose:
            </p>
            <ul>
              <li>
                <strong>Name</strong>, for example <em>Claude Work</em>. It becomes the app's name.
              </li>
              <li>
                <strong>Number</strong>, the badge on the icon.
              </li>
              <li>
                <strong>Colour</strong>: {colours.join(", ")}.
              </li>
              <li>
                <strong>Icon style</strong> and an optional <strong>label</strong> such as <code>WORK</code>, drawn as a
                strip across the icon.
              </li>
              <li>
                <strong>Connect with</strong>: a Claude account (the default) or an API key. See{" "}
                <a href="#api-instances">API instances</a>.
              </li>
            </ul>
            <p>
              Click <strong>Create</strong>. Seatbay writes <code>~/Applications/Claude Work.app</code>, about 200 KB. Open
              it from Seatbay, Spotlight, Raycast, Alfred or Finder, or drag it to the Dock.
            </p>
            <div className="callout">
              <p>
                <strong>Pin from ~/Applications.</strong> Drag the instance app from <code>~/Applications</code> to the
                Dock. “Keep in Dock” on a running instance stores the path of its temporary copy; it still opens the
                instance, but the tile may not show the right icon.
              </p>
            </div>
            <p>
              If you change an instance's look while it's running, quit and reopen it to see the new icon. To remove an
              instance, choose <strong>⋯ → Delete…</strong> on its row. The app goes to the Trash, and its data folder too
              if you pick <strong>Delete App and Data</strong>.
            </p>
          </section>

          {/* Sign in */}
          <section aria-labelledby="sign-in">
            <h2 id="sign-in">Sign in</h2>
            <p>
              Click <strong>Sign In…</strong> next to an instance and sign in as usual. You don't need to quit your other
              Claudes.
            </p>
            <p>
              Google and email sign-in finish with the browser opening a <code>claude://</code> link, which macOS would
              normally hand to your main Claude. During Sign In…, Seatbay briefly becomes the <code>claude://</code>{" "}
              handler, sends the link straight to the chosen instance as a standard “open URL” Apple Event, and then gives
              the link type back to Claude.
            </p>
            <p>
              The first time, macOS asks whether <strong>Seatbay</strong> may control <strong>Claude</strong>. Allow it,
              or the link can't be delivered. From a script:
            </p>
            <Code code={`open -a Seatbay --args --sign-in "Claude Work"`} />
          </section>

          {/* API */}
          <section aria-labelledby="api-instances">
            <h2 id="api-instances">API instances</h2>
            <p>
              Claude Desktop can use an API key or a gateway instead of a Claude account (it calls this third-party
              inference). To set it up for one instance, pick <strong>Connect with: API key</strong> when you create or
              edit it:
            </p>
            <ul>
              <li>
                <strong>Base URL</strong>: leave it blank for Anthropic's API, or enter any Anthropic-compatible gateway.
                Use the address Claude adds <code>/v1/messages</code> to.
              </li>
              <li>
                <strong>API key</strong>, and how the gateway expects it: <code>x-api-key</code> or{" "}
                <code>Authorization: Bearer</code>.
              </li>
              <li>
                Optional <strong>models</strong> (the ids shown in the model menu) and <strong>extra headers</strong>.
              </li>
            </ul>
            <p>
              <strong>Test Connection</strong> asks the API for its model list, which costs no tokens. An API instance has
              no Sign In… button, and its icon carries an <strong>API</strong> tag in the bottom-left corner.
            </p>
            <h3 id="api-how">How it's stored</h3>
            <p>
              Claude reads third-party settings from <code>configLibrary/</code> in a data folder whose name ends in{" "}
              <code>-3p</code>, so an API instance's data lives in <code>Instances/&lt;id&gt;-3p</code>. Seatbay writes
              the entry the way Claude's own setup window does. The first time the instance starts, Claude seals the key
              with a key held in the macOS keychain.
            </p>
            <p>
              Switching an instance between an account and an API key keeps both folders, so switching back finds the old
              sign-in or API settings and history again.
            </p>
            <h3 id="api-cli">From the command line</h3>
            <Code
              label="api.json"
              lang="json"
              code={`{
  "baseURL": "https://gateway.example.com/anthropic",
  "apiKey": "…",
  "authScheme": "bearer",
  "models": ["model-id-1", "model-id-2"],
  "headers": { "x-team": "research" }
}`}
            />
            <Code
              code={`${S}
"$S" --configure-api "Claude Work" < api.json   # authScheme: x-api-key or bearer
"$S" --api-status "Claude Work"
"$S" --api-test "Claude Work"                   # a key Claude has sealed can't be tested
"$S" --configure-api "Claude Work" account      # back to a Claude account`}
            />
            <div className="callout">
              <p>
                <strong>Sealed keys stay on this Mac.</strong> After Claude seals a key, it only works with this Mac's
                keychain. A backup restored on another Mac needs the key entered again, and copying profiles never copies
                API settings. To test a sealed key from Seatbay, type it again.
              </p>
            </div>
          </section>

          {/* Backups */}
          <section aria-labelledby="backups">
            <h2 id="backups">Backups and S3</h2>
            <p>
              A backup is a <code>tar.gz</code> of one Claude's data folder, without caches and things that download again
              (<code>Cache</code>, <code>Code Cache</code>, GPU caches, <code>Logs</code>, <code>vm_bundles</code>,{" "}
              <code>claude-code</code> and so on). It holds the sign-in, settings and local session data, for your main
              Claude and for every instance. A backup is usually a few MB.
            </p>
            <h3 id="backups-when">When backups are taken</h3>
            <ul>
              <li>
                <strong>On quit</strong>: each time a Claude quits, at most once every 6 hours per Claude.
              </li>
              <li>
                <strong>Nightly</strong>, once you turn it on: see <a href="#nightly-schedule">Nightly schedule</a>.
              </li>
              <li>During a safe update, and when an instance is put to sleep.</li>
              <li>
                <strong>Back Up Now</strong> on a row, or <strong>Back Up Everything Now</strong> for the whole nightly
                round at once.
              </li>
            </ul>
            <p>
              Backups are kept in <code>~/Library/Application Support/Seatbay/Snapshots</code>, the last 10 per Claude.
            </p>
            <h3 id="restore">Restore</h3>
            <p>
              Pick a backup in the <strong>Backups</strong> tab. The current data folder is backed up first and then moved
              to the Trash, so a restore can be undone. The big downloaded folders are moved over, so nothing downloads
              again.
            </p>
            <p>
              <strong>Restore as a New Instance</strong> creates a new instance from a backup in your bucket, for example
              one made on another Mac or of an instance you deleted. Sessions, settings and MCP config come back; the
              sign-in only carries over on the Mac that made the backup.
            </p>

            <h3 id="s3">Encrypted upload to S3-compatible storage</h3>
            <p>
              Backups can be uploaded to AWS S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO and other S3-compatible
              services. Each one is encrypted on your Mac with <strong>AES-256-GCM</strong> before upload, with a key
              derived from your passphrase (PBKDF2-HMAC-SHA256, 600,000 rounds, a random salt per file), and can be
              restored on another Mac with the same passphrase. Each Mac uploads to its own folder in the bucket.
            </p>
            <ol>
              <li>Create a bucket, and an access key that can read, write, list and delete in it.</li>
              <li>
                In Seatbay's <strong>Backups</strong> tab, enter the endpoint, region, bucket, prefix, access key, secret
                and a passphrase (typed twice).
              </li>
              <li>Test the connection. It writes, reads, lists and deletes a small test object.</li>
            </ol>
            <div className="table-wrap">
              <table>
                <caption>Endpoint and region for common providers</caption>
                <thead>
                  <tr>
                    <th scope="col">Provider</th>
                    <th scope="col">Endpoint</th>
                    <th scope="col">Region</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <th scope="row">AWS S3</th>
                    <td>
                      <code>https://s3.&lt;region&gt;.amazonaws.com</code>
                    </td>
                    <td>
                      your bucket's region, e.g. <code>eu-west-1</code>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Cloudflare R2</th>
                    <td>
                      <code>https://&lt;account-id&gt;.r2.cloudflarestorage.com</code>
                    </td>
                    <td>
                      <code>auto</code>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Backblaze B2</th>
                    <td>
                      <code>https://s3.&lt;region&gt;.backblazeb2.com</code>
                    </td>
                    <td>
                      the bucket's region, e.g. <code>us-west-004</code>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Wasabi</th>
                    <td>
                      <code>https://s3.&lt;region&gt;.wasabisys.com</code>
                    </td>
                    <td>
                      the bucket's region, e.g. <code>eu-central-1</code>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">MinIO</th>
                    <td>your server's URL</td>
                    <td>
                      usually <code>us-east-1</code>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p>
              Path-style URLs are on by default, which MinIO and most S3-compatible services need. From the command line:
            </p>
            <Code
              label="s3.json (Cloudflare R2)"
              lang="json"
              code={`{
  "enabled": true,
  "endpoint": "https://<account-id>.r2.cloudflarestorage.com",
  "region": "auto",
  "bucket": "my-claude-backups",
  "prefix": "seatbay",
  "accessKeyID": "…",
  "secretAccessKey": "…",
  "passphrase": "a long passphrase you keep elsewhere"
}`}
            />
            <Code
              code={`${S}
"$S" --configure-s3 < s3.json
"$S" --s3-test      # write, read, delete, list
"$S" --s3-list`}
            />
            <div className="callout callout-warn">
              <p>
                <strong>Keep the passphrase somewhere safe.</strong> Without it, uploaded backups can't be decrypted. The
                access key and passphrase are stored in <code>secrets.json</code>, a <code>0600</code> file next to
                Seatbay's settings, not in the Keychain. A backup contains sign-in data: treat the Snapshots folder and the bucket like passwords.
              </p>
            </div>
          </section>

          {/* Nightly */}
          <section aria-labelledby="nightly-schedule">
            <h2 id="nightly-schedule">Nightly schedule</h2>
            <p>
              Seatbay asks once whether to turn nightly backups on. Then, between 2 and 3 AM (you can pick the hour), every
              Claude that changed since its last backup is backed up,
              including the ones that are open: their folder is cloned first, which takes a fraction of a second, and the
              clone is archived, so nothing is closed or interrupted. Then every backup that isn't in S3 yet is uploaded,
              which also retries uploads that failed earlier.
            </p>
            <ul>
              <li>
                A launchd agent, <code>~/Library/LaunchAgents/in.sisara.seatbay.backup.plist</code>, runs the round, so
                Seatbay doesn't have to be open. The first time it's installed, macOS shows a “Background Items Added”
                notice.
              </li>
              <li>
                If the Mac was asleep or off at night, or the round failed (no network, say), it runs as soon as the Mac is
                awake and is retried every 30 minutes until it succeeds. macOS doesn't wake a sleeping Mac for it.
              </li>
              <li>Seatbay warns you when no round has completed for 36 hours.</li>
            </ul>
            <Code
              code={`${S}
"$S" --backup-schedule status   # window, agent, S3, last round, whether one is due
"$S" --backup-schedule hour 3   # move the window to 3–4 AM
"$S" --backup-schedule off      # or on; install refreshes the agent
"$S" --backup-round             # run the round now`}
            />
          </section>

          {/* Updates */}
          <section aria-labelledby="safe-updates">
            <h2 id="safe-updates">Safe updates</h2>
            <p>
              Only your regular Claude looks for and installs updates. Instances have update checks turned off and start
              from the installed version each time they open. An instance that is still open after an update keeps the
              earlier version until you restart it; <strong>Health</strong> shows which ones. Updates are found while the
              regular Claude is open, so open it now and then if you mostly work in instances.
            </p>
            <p>
              <strong>Safe updates</strong> (Updates tab, off by default) does the whole round for you:
            </p>
            <ol>
              <li>checks the signature of the update Claude downloaded,</li>
              <li>closes every Claude and backs each one up,</li>
              <li>runs Claude's own installer,</li>
              <li>reopens what was open.</li>
            </ol>
            <p>
              It can do this by itself while you're away, and it keeps the previous version so <strong>Roll Back</strong>{" "}
              can return to it. <strong>Restart All</strong> runs the same round without an update. This is the only
              feature that changes <code>/Applications/Claude.app</code>, and only with Claude's own update.
            </p>
            <Code
              code={`${S}
"$S" --update-status
"$S" --update-all                                   # the safe-update round
"$S" --restart-all --only "Claude Work,Claude Dev"  # restart just those`}
            />
          </section>

          {/* Health */}
          <section aria-labelledby="health-and-sleep">
            <h2 id="health-and-sleep">Health and sleep</h2>
            <p>
              <strong>Health</strong> lists every Claude with its state (working, idle, closed, sleeping), memory, CPU,
              process count, whether it is signed in, and which version it runs. The main Claude's row is marked{" "}
              <strong>API key</strong> when it is set up with an API key or a cloud provider.
            </p>
            <p>
              <strong>Sleep idle instances</strong> (off by default) quits an instance that has been idle and in the
              background for a set time, 30 minutes by default, and backs it up. Open it to wake it. An instance that is
              working is never put to sleep, and each instance has a <strong>Never put this instance to sleep</strong>{" "}
              switch.
            </p>
            <Code code={`"$S" --health   # one line per Claude: state, memory, CPU, sign-in`} />
          </section>

          {/* Other Mac */}
          <section aria-labelledby="other-mac">
            <h2 id="other-mac">Another Mac</h2>
            <p>
              <strong>Other Mac</strong> installs Seatbay on a second Mac over SSH (key-based, it never prompts for a
              password) and copies your profiles there: names, colours, numbers and labels. Data, sign-ins and API settings
              are not copied, so you sign in on that Mac yourself. Claude Desktop must already be installed there.
            </p>
            <Code
              code={`"$S" --other-mac-status user@host
"$S" --copy-profiles user@host all             # or "Claude Work,Claude Dev"`}
            />
          </section>

          {/* Bypass */}
          <section aria-labelledby="bypass-permissions">
            <h2 id="bypass-permissions">Bypass permissions for Claude Code</h2>
            <p>
              The <strong>Start new Code sessions in Bypass permissions</strong> switch (under Options) asks you to
              confirm, then sets{" "}
              <code>permissions.defaultMode: "bypassPermissions"</code> in <code>~/.claude/settings.json</code>. Claude
              Desktop has no launch flag for its default permission mode; it reads that key from the Claude Code settings
              files. Every Claude reads the same user file, so the switch covers the main Claude, every instance and the
              terminal <code>claude</code> CLI. Running apps pick it up for their next new session.
            </p>
            <p>
              The edit keeps every other setting and the file's key order, and before its first edit Seatbay saves a
              one-time copy as <code>settings.json.seatbay-backup</code>. Each Claude app also has its own{" "}
              <strong>Settings → Claude Code → Allow bypass permissions mode</strong>, stored per account. Seatbay never
              flips that security switch for you: turn it on once in each instance, for each account.
            </p>
            <Code code={`"$S" --bypass-default on   # or off / status`} />
          </section>

          {/* CLI */}
          <section aria-labelledby="command-line">
            <h2 id="command-line">Command line reference</h2>
            <p>
              Everything the app does can be scripted. The binary is inside the app; set a variable once:
            </p>
            <Code code={`${S}\n"$S" --list`} />
            {cli.map((group) => (
              <div key={group.id} className="cli-group">
                <h3 id={group.id}>{group.title}</h3>
                <div className="table-wrap">
                  <table className="cli">
                    <thead>
                      <tr>
                        <th scope="col">Command</th>
                        <th scope="col">What it does</th>
                      </tr>
                    </thead>
                    <tbody>
                      {group.entries.map((e) => (
                        <tr key={e.cmd}>
                          <td>
                            <code>&quot;$S&quot; {e.cmd}</code>
                          </td>
                          <td>{e.what}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            ))}
            <h3 id="cli-sign-in">Sign in</h3>
            <Code code={`open -a Seatbay --args --sign-in "Claude Work"`} />
          </section>

          {/* Files */}
          <section aria-labelledby="files">
            <h2 id="files">Files and folders</h2>
            <div className="table-wrap">
              <table className="files">
                <thead>
                  <tr>
                    <th scope="col">Path</th>
                    <th scope="col">What</th>
                  </tr>
                </thead>
                <tbody>
                  {files.map(([path, what]) => (
                    <tr key={path}>
                      <td>
                        <code>{path}</code>
                      </td>
                      <td>{what}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p>
              Your main Claude keeps using <code>~/Library/Application Support/Claude</code> (or <code>Claude-3p</code> when
              it's set up with an API key); Seatbay never changes it. Instances write their logs to the same{" "}
              <code>~/Library/Logs/Claude</code> as the main app. Installs from before the rename keep using{" "}
              <code>~/Library/Application Support/MultiClaude</code> instead of <code>Seatbay</code>.
            </p>
          </section>

          {/* Uninstall */}
          <section aria-labelledby="uninstall">
            <h2 id="uninstall">Uninstall</h2>
            <ol>
              <li>
                In Seatbay, turn off nightly backups, or run this. Either way removes the launchd agent:
                <Code code={`${site.binary} --backup-schedule off`} />
              </li>
              <li>
                Delete the instances with <strong>⋯ → Delete…</strong> (choose whether to keep their data), or delete their
                apps from <code>~/Applications</code>.
              </li>
              <li>
                Quit Seatbay and move <strong>Seatbay.app</strong> to the Trash.
              </li>
              <li>
                To remove everything, also delete <code>~/Library/Application Support/Seatbay</code> (or{" "}
                <code>MultiClaude</code> on installs from before the rename). That is every instance's data and the local
                backups, so keep any backup you may still need.
              </li>
            </ol>
            <p>
              Your main Claude and its data are not affected. If you turned on Bypass permissions, turn it off first, or
              remove <code>permissions.defaultMode</code> from <code>~/.claude/settings.json</code>. Backups you uploaded
              stay in your bucket until you delete them.
            </p>
          </section>

          {/* Troubleshooting */}
          <section aria-labelledby="troubleshooting">
            <h2 id="troubleshooting">Troubleshooting and known limits</h2>
            <dl className="limits">
              <dt>The menu bar still says “Claude”.</dt>
              <dd>
                The Dock icon is the instance's own, but the menu bar, Force Quit and Activity Monitor still say Claude.
              </dd>
              <dt>After a power loss, an instance opens with my main profile.</dt>
              <dd>
                The clean-up helper couldn't run, and macOS reopened the leftover copy without the instance's data folder.
                While Seatbay is open, it closes such a stray copy and opens the instance properly. Otherwise, quit that
                window and open the instance from its own icon.
              </dd>
              <dt>“Check for Updates…” in an instance reports an error.</dt>
              <dd>Update checks are off in instances. Update from the regular Claude or the Updates tab.</dd>
              <dt>The Dock tile shows the wrong icon.</dt>
              <dd>
                Pin instances from <code>~/Applications</code>, not with “Keep in Dock” on a running instance. After
                changing an instance's look, quit and reopen it.
              </dd>
              <dt>macOS asks for microphone, folder or Automation access again.</dt>
              <dd>
                Privacy permissions may be asked per instance. Instance apps are ad-hoc signed, so when Seatbay rebuilds one
                (after an icon change or a Seatbay update) macOS can ask again.
              </dd>
              <dt>Claude.app is on a different disk.</dt>
              <dd>
                The clone needs Claude.app and your home folder on the same APFS volume. Otherwise the instance runs
                Claude.app directly, as older builds did.
              </dd>
              <dt>A restored backup lost the last few seconds.</dt>
              <dd>
                A backup taken while a Claude is open is like the folder after a power cut, which Claude recovers from; the
                session running at that moment may lose its last few seconds.
              </dd>
              <dt>A backup didn't upload.</dt>
              <dd>
                Uploads over 4.5 GB stay on the Mac (a single upload is limited to 5 GB). Backups are normally a few MB.
                Failed uploads are retried by the next nightly round.
              </dd>
              <dt>Where are the logs?</dt>
              <dd>
                Launch and clean-up notes are in <code>Logs/launcher.log</code> and backup rounds in{" "}
                <code>Logs/backup.log</code>, both under <code>~/Library/Application Support/Seatbay</code>.
              </dd>
            </dl>
            <p>
              Still stuck? <a href={site.issues}>Open an issue on GitHub</a> with your macOS and Claude versions and the
              relevant log lines.
            </p>
          </section>
        </article>
      </div>
    </>
  );
}
