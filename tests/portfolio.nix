# VM test for portfolio.nix: boots the service against generated albums and checks
# the site, the random-track API, seeking (Range requests), cover art and the sandbox.
#
#   nix build .#checks.x86_64-linux.portfolio -L
{ portfolioPackage }:
{ pkgs, ... }:

let
  # Tiny tagged albums, so the test doesn't depend on the real library.
  albums = pkgs.runCommand "portfolio-test-albums" { nativeBuildInputs = [ pkgs.ffmpeg-headless ]; } ''
    tone() { # folder file title album track
      mkdir -p "$out/$1"
      ffmpeg -loglevel error -f lavfi -i sine=frequency=440:duration=2 \
        -metadata title="$3" -metadata artist="as light fell" -metadata album="$4" \
        -metadata track="$5" -metadata date=2021 "$out/$1/$2"
    }
    tone album_a "One.mp3"     One     "Album A" 1
    tone album_a "Two.mp3"     Two     "Album A" 2
    tone album_a "Private.mp3" Private "Album A" 3
    tone album_b "Three.flac"  Three   "Album B" 1
    ffmpeg -loglevel error -f lavfi -i color=c=blue:s=32x32 -frames:v 1 "$out/album_a/cover.jpg"
  '';
in
{
  name = "portfolio";

  nodes.machine = { pkgs, ... }: {
    imports = [ ../portfolio.nix ];
    services.portfolio = {
      enable    = true;
      package   = portfolioPackage;
      musicDirs = [ "/data/music/album_a" "/data/music/album_b" "/data/music/renamed_album" ];
    };
    # Same ownership as main-node: only jellyfin (and its group) can enter /data/music.
    users.users.jellyfin = { isSystemUser = true; group = "jellyfin"; };
    users.groups.jellyfin = { };
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    import json

    base = "http://127.0.0.1:3003"

    def status(path):
        return int(machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' --path-as-is '{base}{path}'"))

    def headers(path, *args):
        out = machine.succeed(f"curl -sf -D - -o /dev/null {' '.join(args)} '{base}{path}'")
        return out.lower()

    machine.wait_for_unit("portfolio.service")
    machine.wait_for_open_port(3003)

    with subtest("site is served"):
        machine.succeed(f"curl -sf {base}/ | grep -q 'Alfred Ricker'")
        machine.succeed(f"curl -sf {base}/assets/css/site.css > /dev/null")

    with subtest("missing album folders don't take the site down"):
        assert status("/api/music/random") == 503

    with subtest("albums are picked up after a restart"):
        machine.succeed(
            "install -d -m 0770 -o jellyfin -g jellyfin /data/music",
            "cp -r --no-preserve=mode ${albums}/album_a ${albums}/album_b /data/music/",
            "chmod -R a+rX /data/music/album_a /data/music/album_b",
            "chmod 0600 /data/music/album_a/Private.mp3",
        )
        machine.systemctl("restart portfolio.service")
        machine.wait_for_open_port(3003)

    with subtest("random picks every readable track, with tags"):
        seen = {}
        for _ in range(40):
            track = json.loads(machine.succeed(f"curl -sf {base}/api/music/random"))
            seen[track["title"]] = track
        # Private.mp3 is 0600, so the sandboxed service can't read it and skips it.
        assert set(seen) == {"One", "Two", "Three"}, seen.keys()
        one, three = seen["One"], seen["Three"]
        assert one["artist"] == "as light fell", one
        assert one["album"] == "Album A" and one["year"] == 2021 and one["track"] == 1, one
        machine.succeed("journalctl -u portfolio.service | grep -q 'skipped 1 file'")

    with subtest("?not= avoids repeating the current track"):
        for _ in range(15):
            track = json.loads(machine.succeed(f"curl -sf '{base}/api/music/random?not={one['id']}'"))
            assert track["id"] != one["id"]

    with subtest("audio supports Range requests, so the player can seek"):
        h = headers(one["audio"], "-H 'Range: bytes=0-99'")
        assert h.startswith("http/1.1 206"), h
        assert "content-type: audio/mpeg" in h and "content-length: 100" in h, h
        assert "content-type: audio/flac" in headers(three["audio"])

    with subtest("cover art"):
        assert "content-type: image/jpeg" in headers(one["cover"])
        assert status(three["cover"]) == 404  # album_b has no cover.jpg and no embedded art

    with subtest("only scanned files are reachable"):
        assert status("/api/music/0000000000000000/audio") == 404
        assert status("/api/music/..%2f..%2fetc%2fpasswd/audio") == 404
        assert status("/api/music/../../etc/passwd") == 404

    with subtest("sandbox: albums are visible, the rest of /data is not"):
        pid = machine.succeed("systemctl show -p MainPID --value portfolio.service").strip()
        machine.succeed(f"nsenter -t {pid} -m test -r /music/album_a/One.mp3")
        machine.fail(f"nsenter -t {pid} -m test -e /data/music/album_a")
        user = machine.succeed(f"ps -o user= -p {pid}").strip()
        assert user != "root", user
  '';
}
