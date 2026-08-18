cask "clipmouse" do
  version "0.2.0"
  sha256 "6b1be1e832250e4d818473ebaa51d29a82bc3440a823def9b83b75426d7ab2b0"

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
