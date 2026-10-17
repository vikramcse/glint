# Demo video

Renders `docs/media/demo.gif` (README) and `docs/media/demo.mp4` (social posts) with [Remotion](https://www.remotion.dev).

Nothing in the video is mocked up except the panel's frame and the typing: each query was run against a real index built with EmbeddingGemma 2, and the result rows are rendered by the app's own `ResultRow`.

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

4. **Add previews** to `public/`: `preview-N` is the file shown full size for scene N (the photo, a PDF page render, the screenshot), and `icon.png` is `App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`.

5. **Render:**

   ```sh
   cd scripts/demo-video && npm install
   npx remotion render src/index.ts Demo out/demo.mp4 --crf=18
   npx remotion render src/index.ts Demo out/demo.gif --codec=gif --every-nth-frame=2 --scale=0.5
   cp out/demo.gif out/demo.mp4 ../../docs/media/
   ```

   `npm run studio` previews the composition. Scenes, captions and timing are in `src/Demo.tsx`.

Remotion is free for individuals and companies with up to three people; see [its license](https://www.remotion.dev/license).
