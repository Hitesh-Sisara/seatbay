// Site-wide values. Change them here, not in components.

export const site = {
  name: "Seatbay",
  url: "https://seatbay.sisara.in",
  tagline: "Run multiple Claude Desktop accounts on one Mac.",
  description:
    "Seatbay is a free, open-source macOS app that runs several Claude Desktop instances side by side, each signed in to its own Claude account or an API key, with its own coloured, numbered Dock icon.",
  repo: "https://github.com/Hitesh-Sisara/seatbay",
  releases: "https://github.com/Hitesh-Sisara/seatbay/releases",
  download: "https://github.com/Hitesh-Sisara/seatbay/releases/latest/download/Seatbay.zip",
  license: "https://github.com/Hitesh-Sisara/seatbay/blob/main/LICENSE",
  issues: "https://github.com/Hitesh-Sisara/seatbay/issues",
  author: { name: "Hitesh Sisara", url: "https://sisara.in" },
  /** Path of the command-line binary inside the installed app. */
  binary: "/Applications/Seatbay.app/Contents/MacOS/Seatbay",
  /** Last content update, used by the sitemap. */
  updated: "2026-11-19",
} as const;

export const nav = [
  { href: "/#features", label: "Features" },
  { href: "/#how-it-works", label: "How it works" },
  { href: "/#install", label: "Install" },
  { href: "/docs", label: "Docs" },
] as const;

export const disclaimer =
  "Seatbay is an independent open-source tool for Claude Desktop. It is not affiliated with, endorsed by or sponsored by Anthropic. “Claude” is a trademark of Anthropic, PBC.";
