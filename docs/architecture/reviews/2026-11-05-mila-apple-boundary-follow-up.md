# Mila Apple boundary follow-up (2026-11-05)

## Scope

This focused review follows the native parity implementation review for
ADR-0235 and ADR-0278. It covers Apple deployment admission and local
notification-device metadata. It does not claim macOS execution; the Swift
tests require the Apple CI toolchain.

## Findings and changes

1. **High — deployment admission used weaker host and identity checks.**
   `MilaDeploymentStore` accepted uppercase and underscore labels, while the
   Rust hostname grammar and the Apple signer/route boundaries reject them.
   `MilaDeploymentSessionCoordinator.signIn` also admitted a caller-supplied
   deployment when only its UUID matched a persisted record, allowing the
   host, port or pinned trust to be substituted before the adapter factory.
   `MilaHostValidation` now provides the shared lowercase ASCII DNS grammar;
   persisted deployments use it, the route parser and signer reuse it, and
   sign-in and selection require exact equality with the persisted value.
   Deployment-store and same-ID substitution regressions cover the boundary.

2. **High — notification metadata crossed deployment boundaries.**
   The Apple notification controller projected every persisted device and
   removed by device ID alone. Two deployments with the same provider ID could
   therefore expose or remove one another's local metadata. The store API is
   now explicitly deployment-scoped for listing and removal, and upsert uses
   `(deployment, id)` identity. A two-deployment controller regression covers
   projection and removal isolation.

## Architecture impact

The changes preserve ADR-0235's deployment-bound trust and device-key policy
and ADR-0278's client-side device CRUD scope. They strengthen existing native
validation and persistence boundaries without changing Porsche commands,
wire formats, provider behavior or authority ownership. No new ADR is needed.

## Verification

`git diff --check` and the focused source inspection pass. Swift package and
test execution remain pending macOS CI because this Linux environment has no
Swift toolchain. The new tests are present in
`MilaDeploymentSessionTests`, `MilaDeviceSignerTests`, `MilaRouteTests` and
`MilaNotificationsTests`.
