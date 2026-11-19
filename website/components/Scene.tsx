// The hero illustration: two instance windows on a desktop and a Dock with numbered Seatbay tiles.
// Plain HTML and CSS, no images and no third-party artwork.

export type TileColor = "violet" | "blue" | "green" | "amber" | "pink" | "teal";

export function Tile({
  n,
  color,
  label,
  api,
  running,
  tip,
  className,
}: {
  n: number;
  color: TileColor;
  label?: string;
  api?: boolean;
  running?: boolean;
  tip?: string;
  className?: string;
}) {
  const cls = ["tile", `tile-${color}`, label ? "has-label" : "", running ? "is-running" : "", className ?? ""]
    .filter(Boolean)
    .join(" ");
  return (
    <span className={cls}>
      {tip ? <span className="tile-tip">{tip}</span> : null}
      <span className="tile-num">{n}</span>
      {label ? <span className="tile-label">{label}</span> : null}
      {api ? <span className="tile-api">API</span> : null}
    </span>
  );
}

function Window({
  className,
  n,
  color,
  name,
  account,
  lines,
}: {
  className: string;
  n: number;
  color: TileColor;
  name: string;
  account: string;
  lines: number[];
}) {
  return (
    <div className={`win ${className}`}>
      <div className="win-bar">
        <span className="win-lights">
          <i />
          <i />
          <i />
        </span>
        <span className="win-title">
          <Tile n={n} color={color} className="tile-xs" />
          {name}
        </span>
        <span className={`win-chip chip-${color}`}>{account}</span>
      </div>
      <div className="win-body">
        <div className="win-side">
          <i />
          <i />
          <i />
          <i />
        </div>
        <div className="win-main">
          {lines.map((w, i) => (
            <i key={i} className={i % 2 ? "msg msg-me" : "msg"} style={{ width: `${w}%` }} />
          ))}
          <span className={`win-input input-${color}`}>
            <b />
          </span>
        </div>
      </div>
    </div>
  );
}

export function DockScene() {
  return (
    <figure
      className="scene"
      role="img"
      aria-label="Illustration: two Claude Desktop windows signed in to different accounts, and a macOS Dock with four Seatbay instances: 1 in violet, 2 in blue with a WORK label, 3 in green and 4 in amber with an API tag. Dots under the icons mark the instances that are running."
    >
      <div className="scene-screen" aria-hidden="true">
        <div className="scene-glow" />
        <Window className="win-a" n={1} color="violet" name="Claude Personal" account="Personal account" lines={[62, 44, 70, 38]} />
        <Window className="win-b" n={2} color="blue" name="Claude Work" account="Work account" lines={[54, 36, 66, 48, 30]} />
        <div className="dock">
          <span className="dock-app app-notes">
            <i />
            <i />
            <i />
          </span>
          <span className="dock-app app-term is-running">
            <b>&gt;_</b>
          </span>
          <span className="dock-sep" />
          <Tile n={1} color="violet" running />
          <Tile n={2} color="blue" label="WORK" running tip="Claude Work" />
          <Tile n={3} color="green" />
          <Tile n={4} color="amber" api running />
        </div>
      </div>
    </figure>
  );
}
