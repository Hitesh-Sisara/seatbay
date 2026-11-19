import type { Metadata } from "next";
import { site } from "@/lib/site";

export const metadata: Metadata = {
  title: "Page not found",
  description: "This page doesn't exist on the Seatbay website.",
};

export default function NotFound() {
  return (
    <section className="page-hero page-hero-404">
      <div className="wrap">
        <p className="eyebrow">404</p>
        <h1>This seat is empty.</h1>
        <p className="lede">
          There's no page at this address. Try the <a href="/">home page</a>, the <a href="/docs">docs</a> or the{" "}
          <a href={site.repo}>GitHub repository</a>.
        </p>
      </div>
    </section>
  );
}
