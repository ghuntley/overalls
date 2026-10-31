# Fleet Lilly hosts read their configured guest images from a read-only
# virtio-blk drive instead of the 9p-shared host /nix/store.
#
# The NixOS test framework shares the runner's store with each VM over 9p. On
# Namespace xl runners that path delivered 2-3.5 MB/s to Lilly's template
# prewarm, so copying the 1.7 GB guest rootfs took 8.5-11.5 min; in machine-test
# run 41164441328 audi-fleet's prewarm ended unconfirmed after 918.9 s, past its
# 900 s deadline. A local erofs drive removes the 9p medium from the copy.

# @cc [owner:ghuntley,label:verification] fleet-image-store-medium-only
# The fixture MUST change only the medium beneath each configured image
# artifact: every bind mount MUST cover the artifact's own resolved
# /nix/store path with a root-owned, read-only regular file of identical size
# built from that same store path, before lilly-hostd, lilly-ownership and
# lilly start. Lilly's configured image paths, its immutable-store
# verification, durable template copy and image I/O deadline MUST remain the
# production code path; the fixture MUST NOT pre-seed templates or the pool.
# An artifact larger than the drive cap stays on the 9p store unchanged.
{ config, lib, pkgs, ... }:
let
  serial = "fleet-images";
  # Published multi-GiB disks (Windows) would not be worth duplicating per VM.
  maximumArtifactBytes = 8 * 1024 * 1024 * 1024;
  imagePaths = map (image: image.path) config.services.lilly.images;
  hostPkgs = config.virtualisation.host.pkgs;
  # Runs on the test runner from the VM start script, with TMPDIR set to the
  # machine's persistent state directory. It reuses an existing drive, so a
  # restarted machine sees the same bytes and inode numbers. It prints only the
  # drive path on stdout.
  buildDrive = hostPkgs.writeShellScript "fleet-image-store-drive" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ hostPkgs.coreutils hostPkgs.gnutar hostPkgs.erofs-utils ]}
    drive="$TMPDIR/fleet-images.erofs"
    if [ ! -e "$drive" ]; then
      list="$TMPDIR/fleet-images.list"
      : > "$list"
      for image in ${lib.escapeShellArgs imagePaths}; do
        for entry in "$image"/*; do
          resolved=$(readlink -f "$entry")
          case "$resolved" in /nix/store/?*) ;; *) continue ;; esac
          test -f "$resolved" || continue
          if [ "$(stat -c %s "$resolved")" -gt ${toString maximumArtifactBytes} ]; then
            echo "fleet-image-store: $resolved exceeds the drive cap; it stays on 9p" >&2
            continue
          fi
          parent=$(dirname "$resolved")
          if [ "$parent" != /nix/store ]; then
            printf '%s\n' "$parent" >> "$list"
          fi
          printf '%s\n' "$resolved" >> "$list"
        done
      done
      sort -u -o "$list" "$list"
      tar --create --absolute-names --no-recursion --verbatim-files-from \
        --transform 'flags=rSh;s|^/nix/store/||' --files-from "$list" \
        | mkfs.erofs --quiet --force-uid=0 --force-gid=0 -T 0 --tar=f "$drive.pending" >&2
      mv "$drive.pending" "$drive"
    fi
    printf '%s' "$drive"
  '';
in
{
  # Appended after the root and fleet pool drives so their virtio order is unchanged.
  virtualisation.qemu.drives = lib.mkAfter [{
    name = serial;
    file = ''"$(${buildDrive})"'';
    driveExtraOpts = { format = "raw"; readonly = "on"; cache = "writeback"; };
    deviceExtraOpts.serial = serial;
  }];

  systemd.services.fleet-image-store = {
    description = "Serve fleet guest images from a local read-only drive";
    wantedBy = [ "multi-user.target" ];
    before = [ "lilly-hostd.service" "lilly-ownership.service" "lilly.service" ];
    requiredBy = [ "lilly-hostd.service" "lilly-ownership.service" "lilly.service" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.coreutils pkgs.findutils pkgs.util-linux config.systemd.package ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      set -euo pipefail
      device=/dev/disk/by-id/virtio-${serial}
      udevadm wait --timeout=60 "$device"
      store=/run/fleet-image-store
      mkdir -p "$store"
      mountpoint -q "$store" || mount -t erofs -o ro "$device" "$store"
      cd "$store"
      find . -type f -printf '%P\n' | while IFS= read -r relative; do
        target="/nix/store/$relative"
        if mountpoint -q "$target"; then continue; fi
        test -f "$target"
        test ! -L "$target"
        test "$(stat -c %s "$target")" = "$(stat -c %s "$relative")"
        test "$(stat -c %u:%a "$relative")" = "0:$(stat -c %a "$target")"
        mount --bind -o ro "$store/$relative" "$target"
        echo "fleet-image-store: $target served from $device"
      done
    '';
  };
}
