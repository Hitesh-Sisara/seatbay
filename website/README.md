# Seatbay website

The marketing and docs site for [Seatbay](https://seatbay.sisara.in), built with
[vinext](https://github.com/cloudflare/vinext) (the Next.js App Router API on Vite) and deployed as
a Cloudflare Worker named `seatbay-website` on the custom domain `seatbay.sisara.in`.

Every route is prerendered to static HTML at build time and served from Workers static assets.
There are no cookies, no analytics and no external font or script requests; the FAQ and the mobile
menu use native `<details>`.

## Pages

| Path | What it is |
| --- | --- |
| `/` | Landing: hero with the Dock illustration, features, how it works, API instances, backups, `open -n` comparison, install, FAQ |
| `/docs` | The guide: install, instances, sign-in, API instances, backups and S3/R2, schedule, safe updates, health, other Mac, CLI reference, files, uninstall, troubleshooting |
| `/privacy` | The app collects nothing; the site uses no cookies or analytics |
| 404 | `app/not-found.tsx` |

`sitemap.xml`, `robots.txt` and `manifest.webmanifest` are generated from `app/`. Per-page
metadata (title, description, canonical, Open Graph, Twitter card) comes from `pageMeta()` in
`lib/seo.ts`; JSON-LD (SoftwareApplication, SoftwareSourceCode, FAQPage, BreadcrumbList, WebSite)
is built there too. Site-wide values (URLs, download link, author) live in `lib/site.ts`, and the
FAQ and command-line reference in `lib/content.ts`.

## Develop

Node 24 and pnpm.

```sh
pnpm install
pnpm dev             # vite dev server with HMR
pnpm typecheck       # tsc --noEmit
pnpm build           # production build, prerenders every route into dist/
pnpm start           # serve the built Worker locally with wrangler (workerd) on http://localhost:8787
```

## Deploy

```sh
pnpm install
pnpm build
CLOUDFLARE_API_TOKEN=… pnpm run deploy    # vinext-cloudflare deploy --config dist/server/wrangler.json
```

`wrangler.jsonc` attaches the Worker to `seatbay.sisara.in` as a custom domain (`workers_dev` is
off), so the `sisara.in` zone must be on the same Cloudflare account. Cloudflare creates the DNS
record and certificate on the first deploy; delete any existing A, AAAA or CNAME record for
`seatbay.sisara.in` first.

Check it afterwards:

```sh
curl -sI https://seatbay.sisara.in | head -5
curl -s https://seatbay.sisara.in/robots.txt
curl -s https://seatbay.sisara.in/sitemap.xml
```

## Icons and the Open Graph image

`public/seatbay-icon.svg` and `public/seatbay-mark.svg` are copies of the logo in `../assets/`.
The PNGs and `favicon.ico` in `public/` are rendered from those and from `design/*.svg` by
`scripts/render-icons.sh` (needs `rsvg-convert` and ImageMagick). They are committed, so run it
only when the artwork changes:

```sh
pnpm icons
```

## Notices

Seatbay is an independent open-source project and is not affiliated with, endorsed by or sponsored
by Anthropic. "Claude" is a trademark of Anthropic, PBC. The site uses no Anthropic or Claude logos
or artwork; every illustration is drawn in HTML, CSS and SVG for this site.
