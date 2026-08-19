cask "clipmouse" do
  version "0.2.0"
  sha256 "2ba80668576cc7f843f99b25ef019e996aaffd214361ca23ff60fea32d422424"

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
