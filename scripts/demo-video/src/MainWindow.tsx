import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from "remotion";

// Screenshots of the real main window, recorded by UITests/DemoRecording.swift against the demo
// library with EmbeddingGemma 2 (public/main/NNNN.png). Each shot is held for a number of frames.
type Shot = { file: number; hold: number };

const range = (from: number, to: number, hold: number): Shot[] =>
  Array.from({ length: to - from + 1 }, (_, index) => ({ file: from + index, hold }));

// zoom: how far to push in on the search field, results and inspector while searching.
type Beat = { shots: Shot[]; caption: string; detail: string; zoom: number };

const beats: Beat[] = [
  {
    shots: [{ file: 3, hold: 25 }, { file: 4, hold: 25 }, { file: 5, hold: 25 }],
    caption: "Your whole library, in one window",
    detail: "Photos, video, audio, PDFs and documents",
    zoom: 1,
  },
  {
    shots: [...range(8, 33, 3), { file: 34, hold: 12 }, { file: 35, hold: 12 }, ...range(36, 38, 22)],
    caption: "Search by meaning",
    detail: "“red car parked under trees” → IMG_4657.jpg",
    zoom: 1.15,
  },
  {
    shots: [...range(40, 50, 3), { file: 51, hold: 12 }, { file: 52, hold: 12 }, ...range(53, 55, 22)],
    caption: "Ranked on your Mac's GPU",
    detail: "No cloud, no account, no upload",
    zoom: 1.15,
  },
];

const beatLength = (beat: Beat) => beat.shots.reduce((sum, shot) => sum + shot.hold, 0);
export const mainWindowDuration = beats.reduce((sum, beat) => sum + beatLength(beat), 0);

const font = '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif';
// The window is 3024 × 1898 px; shown 1400 px wide.
const width = 1400;
const height = Math.round((width * 1898) / 3024);

export const MainWindow = () => {
  const frame = useCurrentFrame();
  // Find the beat and the shot on screen at this frame.
  let beatIndex = beats.length - 1;
  let beatStart = mainWindowDuration - beatLength(beats[beatIndex]);
  for (let index = 0, start = 0; index < beats.length; start += beatLength(beats[index]), index++) {
    if (frame < start + beatLength(beats[index])) {
      beatIndex = index;
      beatStart = start;
      break;
    }
  }
  let current = beats[beatIndex].shots[beats[beatIndex].shots.length - 1];
  for (let index = 0, start = beatStart; index < beats[beatIndex].shots.length; index++) {
    start += beats[beatIndex].shots[index].hold;
    if (frame < start) {
      current = beats[beatIndex].shots[index];
      break;
    }
  }
  const beat = beats[beatIndex];
  const local = frame - beatStart;
  const length = beatLength(beat);
  const zoom = interpolate(local, [0, 45], [beatIndex === 1 ? 1 : beat.zoom, beat.zoom], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const appear = interpolate(frame, [0, 10], [0, 1], { extrapolateRight: "clamp" });
  const captionOpacity = interpolate(local, [0, 8, length - 6, length], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <AbsoluteFill style={{ fontFamily: font, opacity: appear }}>
      <div
        style={{
          position: "absolute",
          top: 36,
          left: (1920 - width) / 2,
          width,
          height,
          borderRadius: 22,
          overflow: "hidden",
          boxShadow: "0 40px 120px rgba(0,0,0,.55), 0 0 0 1px rgba(255,255,255,.12)",
          transform: `scale(${0.97 + 0.03 * appear})`,
        }}
      >
        <Img
          src={staticFile(`main/${String(current.file).padStart(4, "0")}.png`)}
          style={{ width, height, display: "block", transform: `scale(${zoom})`, transformOrigin: "97% 0%" }}
        />
      </div>
      <div style={{ position: "absolute", bottom: 46, width: "100%", textAlign: "center", opacity: captionOpacity }}>
        <span style={{ fontSize: 44, fontWeight: 700, color: "white", textShadow: "0 4px 30px rgba(0,0,0,.6)" }}>{beat.caption}</span>
        <span style={{ fontSize: 28, color: "rgba(255,255,255,.75)", marginLeft: 22 }}>{beat.detail}</span>
      </div>
    </AbsoluteFill>
  );
};
