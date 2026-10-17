import { Composition } from "remotion";
import { Demo, demoDuration } from "./Demo";

export const Root = () => (
  <Composition id="Demo" component={Demo} durationInFrames={demoDuration} fps={30} width={1600} height={1000} />
);
