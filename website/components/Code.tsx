// A static code block. Shell comments (# …) are dimmed; no client-side highlighting.

function renderLine(line: string, i: number) {
  const hash = line.startsWith("#") ? 0 : line.indexOf("  #");
  if (hash < 0) return <span key={i}>{line + "\n"}</span>;
  return (
    <span key={i}>
      {line.slice(0, hash)}
      <span className="c">{line.slice(hash)}</span>
      {"\n"}
    </span>
  );
}

export function Code({ code, label, lang = "shell" }: { code: string; label?: string; lang?: string }) {
  const lines = code.replace(/\n$/, "").split("\n");
  return (
    <figure className="code">
      {label ? <figcaption className="code-label">{label}</figcaption> : null}
      <pre tabIndex={0}>
        <code data-lang={lang}>{lines.map(renderLine)}</code>
      </pre>
    </figure>
  );
}
