import { MainWindow, mainWindowDuration } from "./MainWindow";
import { AbsoluteFill, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";

// Each scene types a real query and shows the rows Glint returned for it, rendered by the app's
// own ResultRow (public/rows-N.png, from DemoRenderTests), then a preview of the matched file.
type Scene = { query: string; rows: string; preview: string; caption: string; detail: string };

const scenes: Scene[] = [
  {
    query: "dog splashing in a river",
    rows: "rows-0.png",
    preview: "preview-0.jpg",
    caption: "Finds photos by what's in them",
    detail: "The file is called IMG_4517.jpg",
  },
  {
    query: "pricing slide",
    rows: "rows-2.png",
    preview: "preview-2.png",
    caption: "PDFs open at the matching page",
    detail: "Acme pitch.pdf, page 2",
  },
  {
    query: "boarding pass",
    rows: "rows-3.png",
    preview: "preview-3.png",
    caption: "Screenshots, by the words in them",
    detail: "Text is read with on-device OCR",
  },
];

const intro = 45;
const sceneLength = 120;
const outro = 105;
const panelEnd = intro + scenes.length * sceneLength;
export const demoDuration = panelEnd + mainWindowDuration + outro;

const font = '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif';
const panelWidth = 1152; // the panel's 720 pt at 1.6×

const Wallpaper = () => (
  <AbsoluteFill
    style={{
      background:
        "radial-gradient(1200px 800px at 15% 10%, #3b4fd8 0%, transparent 60%), radial-gradient(1000px 700px at 90% 90%, #0f8f8a 0%, transparent 60%), linear-gradient(135deg, #141b3a 0%, #0b2533 100%)",
    }}
  />
);

const Keycaps = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const pop = spring({ frame, fps, config: { damping: 14 } });
  const opacity = interpolate(frame, [0, 6, intro - 8, intro], [0, 1, 1, 0], { extrapolateRight: "clamp" });
  const cap = (label: string, width: number) => (
    <div
      style={{
        width,
        height: 96,
        borderRadius: 18,
        background: "linear-gradient(#f4f4f6, #d9dadf)",
        boxShadow: "0 6px 0 #a9abb3, 0 14px 30px rgba(0,0,0,.35)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontFamily: font,
        fontSize: 40,
        color: "#222",
        fontWeight: 500,
      }}
    >
      {label}
    </div>
  );
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity }}>
      <div style={{ display: "flex", gap: 22, transform: `scale(${0.8 + 0.2 * pop})` }}>
        {cap("⌥", 110)}
        {cap("space", 300)}
      </div>
    </AbsoluteFill>
  );
};

const Magnifier = () => (
  <svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="rgba(235,235,245,.6)" strokeWidth="2.4" strokeLinecap="round">
    <circle cx="10.5" cy="10.5" r="7" />
    <path d="M16 16l5.5 5.5" />
  </svg>
);

const KeyHint = ({ keys, label }: { keys: string; label: string }) => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
    <span style={{ padding: "1px 8px", borderRadius: 6, background: "rgba(255,255,255,.12)" }}>{keys}</span>
    {label}
  </span>
);

const Panel = ({ scene }: { scene: Scene }) => {
  const frame = useCurrentFrame();
  const typeStart = 4;
  const typed = scene.query.slice(0, Math.max(0, Math.floor((frame - typeStart) / 1.6)));
  const typedAt = typeStart + scene.query.length * 1.6;
  // Results merge in 40 ms after the last keystroke, plus the query embedding.
  const resultsAt = typedAt + 3;
  const resultsOpacity = interpolate(frame, [resultsAt, resultsAt + 5], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const caret = Math.floor(frame / 8) % 2 === 0 || frame < typedAt;
  return (
    <div
      style={{
        position: "absolute",
        top: 140,
        left: (1920 - panelWidth) / 2,
        width: panelWidth,
        borderRadius: 39,
        overflow: "hidden",
        background: "rgba(38,38,44,.78)",
        backdropFilter: "blur(40px) saturate(1.6)",
        border: "1.5px solid rgba(255,255,255,.14)",
        boxShadow: "0 40px 120px rgba(0,0,0,.55)",
        fontFamily: font,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 15, padding: "21px 27px" }}>
        <Magnifier />
        <div style={{ fontSize: 33, color: typed ? "#f2f2f7" : "rgba(235,235,245,.35)", letterSpacing: 0.2 }}>
          {typed || "Search anything"}
          <span style={{ opacity: caret ? 1 : 0, color: "#4c8dff", marginLeft: 1 }}>|</span>
        </div>
      </div>
      <div style={{ height: 1, background: "rgba(255,255,255,.1)" }} />
      <div style={{ opacity: resultsOpacity, paddingBottom: 6 }}>
        <Img src={staticFile(scene.rows)} style={{ width: panelWidth, display: "block" }} />
      </div>
      <div style={{ height: 1, background: "rgba(255,255,255,.1)" }} />
      <div
        style={{
          display: "flex",
          justifyContent: "flex-end",
          gap: 26,
          padding: "12px 24px",
          fontSize: 17,
          color: "rgba(235,235,245,.55)",
        }}
      >
        <KeyHint keys="↩" label="Open" />
        <KeyHint keys="␣" label="Quick Look" />
        <KeyHint keys="⌘↩" label="Show in Finder" />
      </div>
    </div>
  );
};

const Preview = ({ scene }: { scene: Scene }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const start = 62;
  const rise = spring({ frame: frame - start, fps, config: { damping: 16 } });
  if (frame < start) return null;
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", background: `rgba(0,0,0,${0.45 * rise})` }}>
      <Img
        src={staticFile(scene.preview)}
        style={{
          maxWidth: 1200,
          maxHeight: 660,
          borderRadius: 18,
          boxShadow: "0 40px 120px rgba(0,0,0,.6)",
          transform: `translateY(${(1 - rise) * 60}px) scale(${0.92 + 0.08 * rise})`,
          opacity: rise,
          marginTop: -60,
          background: "white",
        }}
      />
    </AbsoluteFill>
  );
};

const Caption = ({ scene }: { scene: Scene }) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [40, 50, sceneLength - 8, sceneLength], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", paddingBottom: 70, opacity, fontFamily: font }}>
      <div style={{ fontSize: 52, fontWeight: 700, color: "white", textShadow: "0 4px 30px rgba(0,0,0,.6)" }}>{scene.caption}</div>
      <div style={{ fontSize: 28, color: "rgba(255,255,255,.75)", marginTop: 10 }}>{scene.detail}</div>
    </AbsoluteFill>
  );
};

const Outro = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const pop = spring({ frame, fps, config: { damping: 15 } });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", fontFamily: font, opacity: pop }}>
      <Img src={staticFile("icon.png")} style={{ width: 200, height: 200, transform: `scale(${0.85 + 0.15 * pop})` }} />
      <div style={{ fontSize: 84, fontWeight: 800, color: "white", marginTop: 18 }}>Glint</div>
      <div style={{ fontSize: 36, color: "rgba(255,255,255,.85)", marginTop: 6 }}>On-device multimodal search for the Mac</div>
      <div style={{ fontSize: 28, color: "rgba(255,255,255,.65)", marginTop: 26 }}>
        Photos · video · audio · PDFs · documents — nothing leaves your Mac
      </div>
      <div style={{ fontSize: 30, color: "#8fb8ff", marginTop: 34, fontWeight: 600 }}>github.com/vikramcse/glint</div>
    </AbsoluteFill>
  );
};

export const Demo = () => (
  <AbsoluteFill style={{ backgroundColor: "#0b1020" }}>
    <Wallpaper />
    <Sequence durationInFrames={intro}>
      <Keycaps />
    </Sequence>
    {scenes.map((scene, index) => (
      <Sequence key={scene.query} from={intro + index * sceneLength} durationInFrames={sceneLength}>
        <Panel scene={scene} />
        <Preview scene={scene} />
        <Caption scene={scene} />
      </Sequence>
    ))}
    <Sequence from={panelEnd} durationInFrames={mainWindowDuration}>
      <MainWindow />
    </Sequence>
    <Sequence from={panelEnd + mainWindowDuration}>
      <Outro />
    </Sequence>
  </AbsoluteFill>
);
