cask "clipmouse" do
  version "0.2.1"
  sha256 "2ef746860640d4f1c138a29982268d061ae440afe93506c0d1b6b1245196f183"

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
