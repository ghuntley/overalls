---
modules: [Marshall.Compute, Marshall.Compute.AddressAllocation, Marshall.Compute.AdminHostConfiguration, Marshall.Compute.AdminViews, Marshall.Compute.Admission, Marshall.Compute.AdvanceDrain, Marshall.Compute.AdvanceEvacuation, Marshall.Compute.Budget, Marshall.Compute.CapacityPolicy, Marshall.Compute.Changes.ValidateImage, Marshall.Compute.CleanupRequest, Marshall.Compute.CloneCoordinator, Marshall.Compute.CloneDispatch, Marshall.Compute.CloneEffect, Marshall.Compute.CloneEffects, Marshall.Compute.CloneFailure, Marshall.Compute.CloneGuard, Marshall.Compute.ClonePlacement, Marshall.Compute.CloneRequest, Marshall.Compute.Cloning, Marshall.Compute.CommandSnapshot, Marshall.Compute.CredentialLifetime, Marshall.Compute.Credentials, Marshall.Compute.DestinationReceiveDispatch, Marshall.Compute.Dispatch, Marshall.Compute.Drains, Marshall.Compute.Enrollment, Marshall.Compute.EnrollmentOperation, Marshall.Compute.EnrollmentPreparation, Marshall.Compute.EnrollmentRequest, Marshall.Compute.Error, Marshall.Compute.Evacuation, Marshall.Compute.EvacuationActions, Marshall.Compute.EvacuationItem, Marshall.Compute.EvacuationViews, Marshall.Compute.Evacuations, Marshall.Compute.ExpireLifecycleEvents, Marshall.Compute.Host, Marshall.Compute.HostCredential, Marshall.Compute.HostDrain, Marshall.Compute.HostLiveness, Marshall.Compute.HostReports, Marshall.Compute.HostSession, Marshall.Compute.Image, Marshall.Compute.Images, Marshall.Compute.Ledger, Marshall.Compute.Lifecycle, Marshall.Compute.LifecycleAudit, Marshall.Compute.LifecycleEvent, Marshall.Compute.LifecycleHistory, Marshall.Compute.LifecycleLog, Marshall.Compute.NativeGuid, Marshall.Compute.NetworkAddress, Marshall.Compute.Operation, Marshall.Compute.Outcomes, Marshall.Compute.PhysicalOutcome, Marshall.Compute.ProbeDispatch, Marshall.Compute.ProbeRequest, Marshall.Compute.ProbeRequestPayload, Marshall.Compute.Profiles, Marshall.Compute.ProvisionerControl, Marshall.Compute.ProvisionerRequests, Marshall.Compute.ReadinessRequest, Marshall.Compute.Relocation, Marshall.Compute.RelocationAdmission, Marshall.Compute.RelocationAdvance, Marshall.Compute.RelocationCancellation, Marshall.Compute.RelocationCapacity, Marshall.Compute.RelocationCleanup, Marshall.Compute.RelocationCoordinator, Marshall.Compute.RelocationDeletion, Marshall.Compute.RelocationDestinationCleanups, Marshall.Compute.RelocationDestinationRevocations, Marshall.Compute.RelocationGuard, Marshall.Compute.RelocationImports, Marshall.Compute.RelocationKeyDispatch, Marshall.Compute.RelocationKeyRetirement, Marshall.Compute.RelocationKeys, Marshall.Compute.RelocationProbes, Marshall.Compute.RelocationReadiness, Marshall.Compute.RelocationReadinessState, Marshall.Compute.RelocationReceives, Marshall.Compute.RelocationRestoration, Marshall.Compute.RelocationRetry, Marshall.Compute.RelocationRetryAdmission, Marshall.Compute.RelocationRevocations, Marshall.Compute.RelocationSnapshotCleanups, Marshall.Compute.RelocationSources, Marshall.Compute.RelocationStatus, Marshall.Compute.Reservation, Marshall.Compute.Resize, Marshall.Compute.ResizeRequest, Marshall.Compute.RestartCapacity, Marshall.Compute.ServiceLevelAdmission, Marshall.Compute.ServiceLevelAttempt, Marshall.Compute.ServiceLevelPublisher, Marshall.Compute.ServiceLevelTotal, Marshall.Compute.ServiceLevelTotals, Marshall.Compute.ServiceLevels, Marshall.Compute.SourcePermitDispatch, Marshall.Compute.SourcePermitRequest, Marshall.Compute.SourceRequestPayload, Marshall.Compute.StartupHolds, Marshall.Compute.StoragePool, Marshall.Compute.TransferDescriptor, Marshall.Compute.TransferEndpoint, Marshall.Compute.TransferPublicKey, Marshall.Compute.TransferSlot, Marshall.Compute.TransferSlots, Marshall.Compute.Views, Marshall.Compute.VirtualMachine, Marshall.Compute.WorkflowServiceLevelAttempt, Marshall.Compute.WorkflowServiceLevels, Marshall.Compute.WorkloadPlacement, Marshall.Compute.WorkspaceSource, Marshall.Control.Concurrency, Marshall.Control.FaultGate, Marshall.Control.Hints, Marshall.Control.Hints.Change, Marshall.Control.Hints.Hosts, Marshall.Control.Hints.Relay, Marshall.Control.Service, Marshall.Control.Services.Audi, Marshall.Control.Services.Galileo, Marshall.Control.Services.Lilly, Marshall.Control.Services.Porsche, Marshall.Control.Services.Ziggy, Marshall.Control.Socket]
---

# Compute obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### marshall.compute.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### marshall.compute.I2 — Inception admission is bound to configured image and capacity
- **scope:** `Marshall.Compute.Profiles.validate/1` and `host_ready?/2`
- **must:** Inception requests MUST use the configured image, satisfy minimum resources, and require matching host inventory evidence.
- **kind:** functional
- **status:** active

### marshall.compute.I3 — Inception shape preserves service minima
- **scope:** `Marshall.Compute.Profiles.default_shape/2`
- **must:** Inception defaults MUST retain at least the configured vCPU, memory, and disk minima regardless of image-provided values; ordinary profiles MUST retain the image shape.
- **kind:** functional
- **status:** active

### marshall.compute.I4 — Delete refusals keep the owner-pin reason closed
- **scope:** `Marshall.Compute.Error` for the lifecycle owner-pin guard (ADR-0193)
- **must:** The guard's refusal MUST be the stable `machine_pinned` reason carried by `Marshall.Compute.Error`, whose message names only that reason; the reason MUST be in the SSH control API's closed 409 set and in Porsche's refined conflict reasons, so no path renders a different or open-ended text.
- **kind:** security
- **status:** active

### marshall.compute.I5 — Lilly control sockets run a bounded FIFO of requests
- **scope:** `Marshall.Control.Socket` request dispatch with `Marshall.Control.Concurrency` (ADR-0275)
- **must:** A Lilly-limited socket MUST run at most its configured `running` requests at once, MUST start accepted requests in arrival order, MUST keep running plus queued within the advertised `in_flight` (refusing only beyond it as `busy`), and MUST answer a request that waited past the queue deadline `temporarily_unavailable` without starting it.
- **kind:** non-functional
- **status:** active
