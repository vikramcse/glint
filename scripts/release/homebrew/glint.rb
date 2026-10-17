# Homebrew cask for Glint, for a tap such as vikramcse/homebrew-tap (Casks/glint.rb).
# Homebrew requires casks to pass Gatekeeper, so publish this only for notarized releases.
# On each release, update `version` and `sha256` (shasum -a 256 Glint-<version>.dmg).
cask "glint" do
  version "1.0.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/vikramcse/glint/releases/download/v#{version}/Glint-#{version}.dmg"
  name "Glint"
  desc "On-device multimodal search for photos, video, audio, PDFs and documents"
  homepage "https://github.com/vikramcse/glint"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Glint.app"
  binary "#{appdir}/Glint.app/Contents/MacOS/glint-mcp"

  zap trash: [
    "~/Library/Application Support/Glint",
    "~/Library/Caches/app.glint.mac",
    "~/Library/Preferences/app.glint.mac.plist",
  ]
end
