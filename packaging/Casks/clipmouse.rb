cask "clipmouse" do
  version "0.1.0"
  sha256 "ac0d09184a1ebf2123c9afbc46f8e1e7f97a060f2da3fa07997b3f6431b0804f"

  url "https://github.com/zeklop/clipmouse/releases/download/v#{version}/ClipMouse-#{version}.dmg"
  name "ClipMouse"
  desc "Native macOS clipboard manager — history, search, snippets, secret protection and keep-awake in one menu bar icon"
  homepage "https://github.com/zeklop/clipmouse"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "ClipMouse.app"

  zap trash: [
    "~/Library/Application Support/ClipMouse",
    "~/Library/Preferences/dev.zeklop.clipmouse.plist",
  ]
end
