# Antithesis image contexts

`antithesis/nix/images.nix` selects the locked `buildNixpkgs` package set for
eight independent `MIX_ENV=prod` OTP releases. `ANTITHESIS_HARNESS=1` is applied
to both `fetchMixDeps` and `mixRelease`; the separate `lilly-guest` variant also
sets `ANTITHESIS_GUEST=1`. The ordinary package set keeps both selectors unset.
The same closed source allowlist supplies the local fallback SDK and Lilly's
harness adapter only for selected releases.
The `pg` stage uses the locked `buildNixpkgs` PostgreSQL 18 closure in a scratch
image. Its entrypoint initializes the private volume under UID 10001, creates
the synthetic oracle role, and refuses incomplete retained initialization.

Each `antithesis-<stage>-context` flake package copies the complete recursive
runtime closure into `rootfs/nix/store`, adds fixed `/bin/sh`, user, CA and
runtime tool links, and writes `identity.json` and
`closure-store-paths.txt` at the context root and inside the image at
`/opt/overalls/image-identity.json` and
`/opt/overalls/closure-store-paths.txt`. The identity records release, source and closure-root
store paths without runtime credentials. Docker builds copy that rootfs from
the repository build context; containers need no host `/nix/store` mount or
runtime download.

After the desired context packages are built, stage them with:

```sh
antithesis/build/prepare-contexts.sh pg marshall lilly workload
docker compose -f antithesis/config/docker-compose.yaml build
```

`prepare-contexts.sh guest-vmm router-vmm lilly-guest` stages the optional VM
images. These outputs include the production NixOS guest image and the separate
stable-NixOS storage router image, their kernels, initrds, complete root images,
QEMU and vhost-user-vsock tools where used. The router image manifest records
exact byte counts and SHA-256 values before the outer runner accepts it. Docker
targets use the corresponding stage names in `antithesis/Dockerfile`.

`prepare-contexts.sh private-host-vmm` selects the integrated Lilly host with
the private guest image and real Audi, Ziggy and Galileo services. Select
`compose.inner-private.yaml` after `compose.host-vmm.yaml` to use this Docker
target and opt into fresh host-bound satellite enrollment. Its CA, role tokens
and synthetic provider keys are generated into runtime volumes. The separate
`host-vmm` target remains the baseline integrated host. The private image has
booted through the direct runner; the Docker variant has not yet been started.

The OTP images contain the fallback Antithesis assertion SDK and a pinned C
single-write helper. This supplies assertion/lifecycle messages and does not
instrument BEAM execution for coverage. The workload image carries Python 3.13
and hash-pinned Python SDK and PostgreSQL wheels. Its assertion catalog is not
part of the Nix context: `selection.py stage` writes the selection-scoped
Python catalog under `antithesis/build/selected-test/catalog/` and the
Dockerfile copies it to `/opt/overalls-antithesis/catalog/`, so the hosted
instrumentor declares only the assertions reachable from the selected commands
and bootstrap. The Nix rootfs carries `/opt/antithesis/catalog` as one symlink
to `/opt/overalls-antithesis/catalog/workload`, which the instrumentor resolves
as a single cataloged root; the Python SDK registers one root's catalog per
process, so the single root is what makes every selected assertion appear in
hosted reports even when no command reaches it. QEMU, the NixOS guests and
Enrico's native Git owner are presently uninstrumented; these images make no
Rust/LLVM coverage or `/symbols` claim.
Emulated guest and router observations are scoped to QEMU TCG. Native KVM,
Firecracker, ZFS host isolation and durability remain governed by their separate
NixOS/native checks. The guest executor admission bridge is not packaged here.
