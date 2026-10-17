import { Composition } from "remotion";
import { Demo, demoDuration } from "./Demo";

export const Root = () => (
  <Composition id="Demo" component={Demo} durationInFrames={demoDuration} fps={30} width={1920} height={1080} />
);
