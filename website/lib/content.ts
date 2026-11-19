// Copy shared between pages (and the JSON-LD built from it).

export type Faq = { q: string; a: string[] };

/** Landing-page FAQ. Plain text so the same words go into the FAQPage JSON-LD. */
export const faq: Faq[] = [
  {
    q: "Can I run multiple Claude Desktop accounts on one Mac at the same time?",
    a: [
      "Yes. Seatbay creates a separate Claude Desktop instance for each account. Every instance has its own sign-in, chats, settings and Cowork sessions, they all run at the same time, and each one has its own coloured, numbered Dock icon. Your regular Claude stays exactly as it is.",
    ],
  },
  {
    q: "Is Seatbay made by Anthropic?",
    a: [
      "No. Seatbay is an independent open-source tool for Claude Desktop, written by Hitesh Sisara. It is not affiliated with, endorsed by or sponsored by Anthropic. “Claude” is a trademark of Anthropic, PBC.",
    ],
  },
  {
    q: "Does Seatbay modify Claude.app?",
    a: [
      "No. Each instance runs from a private APFS clone of the installed Claude.app. The clone is never patched or re-signed, so Claude's code signature and keychain access stay its own, and /Applications/Claude.app is left alone.",
      "The one exception is Safe updates, which is off until you turn it on: it installs the update Claude itself downloaded, using Claude's own installer.",
    ],
  },
  {
    q: "Can an instance use an Anthropic API key or a gateway instead of a Claude account?",
    a: [
      "Yes. Choose “Connect with: API key” when you create or edit an instance. Leave Base URL blank for Anthropic's API, or enter any Anthropic-compatible gateway, then the key, how the gateway expects it (x-api-key or Authorization: Bearer), and optionally the model ids and extra headers.",
      "Test Connection asks the API for its model list, so it costs no tokens. The first time the instance starts, Claude seals the key with the macOS keychain.",
    ],
  },
  {
    q: "How do I back up Claude Desktop?",
    a: [
      "Seatbay backs up your main Claude and every instance when it quits and, once you turn it on, in a nightly round between 2 and 3 AM that includes open instances (they are copied from an instant APFS clone, so nothing is closed). If the Mac was asleep, the round runs when it wakes and retries every 30 minutes until it succeeds.",
      "Backups stay on your Mac, and you can also upload them, encrypted with AES-256-GCM using your passphrase, to any S3-compatible storage: AWS S3, Cloudflare R2, Backblaze B2, Wasabi or MinIO.",
    ],
  },
  {
    q: "Does Seatbay collect any data?",
    a: [
      "No. There is no telemetry, no analytics and no account. Seatbay itself sends nothing anywhere, except backups you choose to upload to your own bucket and profiles you choose to copy to your own second Mac. Each Claude instance talks to Anthropic, or to the gateway you set, just as Claude Desktop always does.",
    ],
  },
  {
    q: "Why does macOS say Seatbay can't be opened?",
    a: [
      "Seatbay is ad-hoc signed and not notarized by Apple, so Gatekeeper stops the first open. Control-click (or right-click) Seatbay in Applications, choose Open, then click Open again. On recent macOS versions, if there is no Open button, go to System Settings → Privacy & Security and click Open Anyway. You only need to do this once.",
    ],
  },
  {
    q: "Do instances get Claude updates?",
    a: [
      "Yes. Your regular Claude finds and installs updates as usual. Instances have update checks turned off and start from the installed version every time they open, so they are always current after a restart. Health shows which open instances still run an older version.",
    ],
  },
  {
    q: "Which Macs does Seatbay run on?",
    a: [
      "macOS 14 Sonoma or later, on Apple silicon or Intel, with Claude Desktop installed in /Applications. Claude.app and your home folder should be on the same APFS volume, which is the normal setup.",
    ],
  },
  {
    q: "Is Seatbay free?",
    a: ["Yes. Seatbay is free and open source under the MIT licence, with no paid tier and no sign-up."],
  },
  {
    q: "What happened to Multi Claude?",
    a: [
      "Seatbay is the new name of Multi Claude. Installs from before the rename keep their instances, data and backups in ~/Library/Application Support/MultiClaude, and they keep working.",
    ],
  },
];

export const faqText = faq.map((f) => ({ q: f.q, text: f.a.join(" ") }));

/** Colours an instance can use (from the app). */
export const colours = [
  "Blue",
  "Green",
  "Purple",
  "Pink",
  "Teal",
  "Red",
  "Amber",
  "Indigo",
  "Brown",
  "Graphite",
  "Black",
  "Orange",
] as const;

export type CliEntry = { cmd: string; what: string };
export type CliGroup = { title: string; id: string; entries: CliEntry[] };

/** The command-line reference. Every command is run as "$S" <args>, with S set to the binary path. */
export const cli: CliGroup[] = [
  {
    title: "Instances",
    id: "cli-instances",
    entries: [
      { cmd: `--create-instance "Claude Work" Blue 2 WORK`, what: "Create an instance: name, colour, number and an optional label." },
      { cmd: `--list`, what: "List the instances." },
      { cmd: `--import-profiles profiles.json`, what: "Create instances from a JSON array of profiles (names, colours, numbers, labels)." },
      { cmd: `--render-preview /tmp/icon.png Green 3 colorAndNumber WORK`, what: "Render an icon preview to a PNG without creating anything." },
    ],
  },
  {
    title: "Health and permissions",
    id: "cli-health",
    entries: [
      { cmd: `--health`, what: "One line per Claude: state, memory, CPU and sign-in." },
      { cmd: `--bypass-default on`, what: "Start new Claude Code sessions in Bypass permissions (or off / status)." },
    ],
  },
  {
    title: "Backups and S3",
    id: "cli-backups",
    entries: [
      { cmd: `--backup all`, what: "Back up every Claude, or main / an instance name. --force skips the 6-hour rule." },
      { cmd: `--list-backups`, what: "List local backups." },
      { cmd: `--restore-snapshot <snapshot id> <main|name>`, what: "Restore a backup into the main Claude or an instance." },
      { cmd: `--backup-round`, what: "Run the nightly round now: every Claude, then upload." },
      { cmd: `--backup-schedule status`, what: "Show the nightly schedule; also on, off, hour 2 and install." },
      { cmd: `--configure-s3 < s3.json`, what: "Set endpoint, region, bucket, prefix, keys and passphrase." },
      { cmd: `--s3-test`, what: "Check the bucket (write, read, delete, list)." },
      { cmd: `--s3-list`, what: "List the backups in the bucket." },
      { cmd: `--s3-upload <snapshot id>`, what: "Upload one backup." },
      { cmd: `--s3-download <machine/target/snapshot> <out.tar.gz>`, what: "Download one backup from the bucket to a file." },
    ],
  },
  {
    title: "API instances",
    id: "cli-api",
    entries: [
      { cmd: `--configure-api "Claude Work" < api.json`, what: "Connect an instance to an API key or gateway." },
      { cmd: `--configure-api "Claude Work" account`, what: "Switch it back to a Claude account." },
      { cmd: `--api-status "Claude Work"`, what: "Show the endpoint, key state, models and header names." },
      { cmd: `--api-test "Claude Work"`, what: "Test the connection (a key Claude has sealed can't be tested)." },
    ],
  },
  {
    title: "Updates and restarts",
    id: "cli-updates",
    entries: [
      { cmd: `--update-status`, what: "Show the installed Claude, a downloaded update waiting to install, and the version kept for Roll Back." },
      { cmd: `--update-all`, what: "Run the safe-update round." },
      { cmd: `--restart-all`, what: "The same round without an update." },
      { cmd: `--restart-all --only "Claude Work,Claude Dev"`, what: "Restart just those instances; a waiting update stays for a full round." },
    ],
  },
  {
    title: "Other Mac",
    id: "cli-other-mac",
    entries: [
      { cmd: `--other-mac-status user@host`, what: "Check macOS, Claude, Seatbay and the instances on the other Mac over SSH." },
      { cmd: `--copy-profiles user@host all`, what: `Install this build of Seatbay there if needed, then copy profiles: all, or "Name,Name".` },
    ],
  },
];
