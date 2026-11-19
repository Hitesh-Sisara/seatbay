import type { Metadata } from "next";
import { site } from "./site";

const ogImage = {
  url: `${site.url}/og-image.png`,
  width: 1200,
  height: 630,
  alt: "Seatbay: run multiple Claude Desktop accounts on one Mac, each with its own numbered Dock icon",
};

/** Per-page metadata: title, description, canonical URL, Open Graph and Twitter card. */
export function pageMeta(opts: {
  path: string;
  title: string;
  description: string;
  absoluteTitle?: boolean;
  noindex?: boolean;
}): Metadata {
  const url = new URL(opts.path, site.url).toString();
  const fullTitle = opts.absoluteTitle ? opts.title : `${opts.title} · Seatbay`;
  return {
    title: opts.absoluteTitle ? { absolute: opts.title } : opts.title,
    description: opts.description,
    alternates: { canonical: url },
    ...(opts.noindex ? { robots: { index: false, follow: true } } : {}),
    openGraph: {
      type: "website",
      url,
      siteName: site.name,
      title: fullTitle,
      description: opts.description,
      locale: "en_US",
      images: [ogImage],
    },
    twitter: {
      card: "summary_large_image",
      title: fullTitle,
      description: opts.description,
      images: [{ url: ogImage.url, alt: ogImage.alt }],
    },
  };
}

export const authorLd = {
  "@type": "Person",
  "@id": `${site.url}/#author`,
  name: site.author.name,
  url: site.author.url,
};

export const websiteLd = {
  "@context": "https://schema.org",
  "@type": "WebSite",
  "@id": `${site.url}/#website`,
  name: site.name,
  url: site.url,
  description: site.description,
  inLanguage: "en",
  publisher: { "@id": `${site.url}/#author` },
};

export const softwareLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "@id": `${site.url}/#software`,
  name: site.name,
  alternateName: "Multi Claude",
  description: site.description,
  url: site.url,
  image: `${site.url}/og-image.png`,
  screenshot: `${site.url}/og-image.png`,
  applicationCategory: "UtilitiesApplication",
  applicationSubCategory: "Productivity",
  operatingSystem: "macOS 14 or later",
  processorRequirements: "Apple silicon or Intel",
  softwareRequirements: "Claude Desktop installed in /Applications",
  downloadUrl: site.download,
  installUrl: site.releases,
  license: "https://opensource.org/licenses/MIT",
  isAccessibleForFree: true,
  codeRepository: site.repo,
  author: authorLd,
  offers: {
    "@type": "Offer",
    price: "0",
    priceCurrency: "USD",
    availability: "https://schema.org/InStock",
    url: site.download,
  },
};

/** SoftwareSourceCode entry so the repository and licence are explicit for crawlers. */
export const sourceCodeLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareSourceCode",
  name: `${site.name} source code`,
  codeRepository: site.repo,
  programmingLanguage: "Swift",
  runtimePlatform: "macOS",
  license: "https://opensource.org/licenses/MIT",
  author: authorLd,
  targetProduct: { "@id": `${site.url}/#software` },
};

export function faqLd(items: { q: string; text: string }[]) {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: items.map((i) => ({
      "@type": "Question",
      name: i.q,
      acceptedAnswer: { "@type": "Answer", text: i.text },
    })),
  };
}

export function breadcrumbLd(items: { name: string; path: string }[]) {
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: items.map((i, n) => ({
      "@type": "ListItem",
      position: n + 1,
      name: i.name,
      item: new URL(i.path, site.url).toString(),
    })),
  };
}
