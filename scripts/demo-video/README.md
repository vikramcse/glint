# Demo video

Renders `docs/media/demo.gif` (README) and `docs/media/demo.mp4` (social posts) with [Remotion](https://www.remotion.dev).

Nothing in the video is mocked up except the search panel's frame and typing. The panel's result rows are rendered by the app's own `ResultRow` from real queries against an EmbeddingGemma 2 index, and the main-window part is screenshots of the real app, recorded by `UITests/DemoRecording.swift`.

## Steps

1. **Build a demo library.** Never use your own files.

   ```sh
   DEMO=/tmp/glint-demo
   swift run glint-eval sample $DEMO/sample && mkdir -p $DEMO/corpus && cp -R $DEMO/sample/corpus/* $DEMO/corpus/
   python3 -I scripts/demo-video/fetch_photos.py $DEMO/corpus/Photos "dog running on beach:2" "vintage red car:2" ...
   ```

   Review the photos, drop off-topic ones and any with identifiable people, then rename them to camera-style names (`IMG_4517.jpg`) so no result can match on a file name. Update `docs/media/CREDITS.md`.

2. **Index it and export results.** This needs the MLX build of `glint-eval` (see [docs/development.md](../../docs/development.md)) and the downloaded model.

   ```sh
   EVAL=build/eval/Build/Products/Release/glint-eval
   MODEL="$HOME/Library/Application Support/Glint/Models/embeddinggemma-2-bf16"
   echo '{"queries":[]}' > $DEMO/queries.json
   $EVAL run $DEMO --model gemma --model-dir "$MODEL" --index-cache $DEMO/index
   $EVAL query "dog splashing in a river" "red car parked under trees" "pricing slide" "boarding pass" \
     --model-dir "$MODEL" --root $DEMO/index --json $DEMO/results.json
   ```

   Optionally rewrite the `path` fields in `results.json` (for example to `/Users/you/Pictures/…`) so the rows don't show a temporary folder.

3. **Render the rows** with the app's views:

   ```sh
   GLINT_DEMO_RESULTS=$DEMO/results.json GLINT_DEMO_OUT=scripts/demo-video/public swift test --filter DemoRenderTests
   ```

4. **Record the main window.** This drives the real app on your screen for about two minutes, so keep hands off the Mac. Window screenshots capture whatever is on screen in the window's frame; the test activates Glint before every frame, but check every frame before using it.

   ```sh
   ROOT="/Users/Shared/Glint Demo"; mkdir -p "$ROOT/Models/embeddinggemma-2-bf16"
   # A real folder of hard links: the model loader doesn't follow a symlinked folder.
   ln "$MODEL"/* "$MODEL"/.*.verified "$ROOT/Models/embeddinggemma-2-bf16/"
   mkdir -p Xcode && xcodegen generate --project Xcode && sed -i '' 's|relativePath = \.;|relativePath = ..;|' Xcode/Glint.xcodeproj/project.pbxproj
   TEST_RUNNER_GLINT_DEMO_ROOT="$ROOT" TEST_RUNNER_GLINT_DEMO_SOURCE=$DEMO/corpus TEST_RUNNER_GLINT_DEMO_WAIT=80 \
     xcodebuild test -project Xcode/Glint.xcodeproj -scheme Glint -destination 'platform=macOS,arch=arm64' \
     -only-testing:GlintAppUITests/DemoRecording/testRecordsMainWindow
   ```

   Frames and `frames.json` land in `~/Library/Containers/app.glint.mac.uitests.xctrunner/Data/tmp/glint-demo-frames`. Copy the ones `src/MainWindow.tsx` uses into `public/main/`.

5. **Add previews** to `public/`: `preview-N` is the file shown full size for scene N (the photo, a PDF page render, the screenshot), and `icon.png` is `App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`.

6. **Render:**

   ```sh
   cd scripts/demo-video && npm install
   ./render.sh        # out/demo.mp4 (1920×1080) and out/demo.gif (1280 px, palette-optimized)
   cp out/demo.gif out/demo.mp4 ../../docs/media/
   ```

   `npm run studio` previews the composition. Panel scenes and captions are in `src/Demo.tsx`, the main-window part in `src/MainWindow.tsx`.

Remotion is free for individuals and companies with up to three people; see [its license](https://www.remotion.dev/license).
