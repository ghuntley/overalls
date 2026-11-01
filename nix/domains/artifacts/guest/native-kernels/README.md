# Native guest kernel inputs

This directory pins FreeBSD 14.3 and the exact OmniOS source corresponding to
the stock r151050 image (`omnios-r151050-6f87d0b5d63`). The latter comes from
`omniosorg/illumos-omnios`, rather than a later illumos or OmniOS branch tip.

FreeBSD uses vendor family 45 (`AF_VENDOR03`), because family 40 already means
`AF_INET_SDP`. Its 16-byte address begins with an 8-bit length and 8-bit family.
The proposed illumos ABI uses the currently unused family 40 and a 16-bit family
without a length byte. Both place port32 at offset 4 and CID32 at offset 8,
followed by four zero bytes. The receipt derivations apply the ABI header patches
and compile layout assertions against the actual pinned operating-system headers.
Illumos now includes a separate public header, modern virtio backport and
bounded socket/transport implementation; its source receipt remains unavailable.

`tools/buck2 build //:package-freebsd-kernel-candidate` builds a complete amd64 GENERIC kernel
with the static FreeBSD socket domain, virtio-vsock PCI/MMIO driver and shared
`common/ov_vsock` wire/credit implementation. The Linux cross-build uses pinned
Clang 19.1.7 (matching FreeBSD 14.3), LLD and host tools, executes the complete
bmake bootstrap test suite, preserves the kernel's warnings-as-errors gate and
fixes the version timestamp. Its host adaptations replace FHS paths and BSD
`date` syntax with the pinned Nix tools; they do not suppress compiler warnings.
For glibc 2.44 hosts, the cross-build headers drop glibc's C23
qualifier-preserving search macros, matching FreeBSD 14.3's plain prototypes,
and mtree's `specspec.c` includes `<sys/stat.h>` directly. The build restores
default SIGINT/SIGQUIT dispositions before bootstrapping, so bmake's interrupt
tests do not depend on signals the Nix daemon left ignored.

The output contains `kernel`, ELF/symbol evidence, a six-field kernel provenance
JSON and a build receipt under `share/overalls/native-kernel`. The aggregate patch
hash binds the ABI patch, driver, public ABI, accepted-child lifetime helper and
shared wire header/core. The configuration
hash binds `freebsd/GENERIC-OVERALLS` and the Nix build recipe. Source revision/hash, compiler and
exact linked kernel bytes/digest remain separately recorded.

The candidate also publishes `include/sys/vsock.h`, with `AF_VSOCK`, wildcard
CID/port constants, host CID and the native `sockaddr_vm` layout. A separate C
consumer compiles size/offset assertions against this public header and the
pinned FreeBSD headers. The closed image constructor stages it for installation
at `/usr/include/sys/vsock.h` through its native first-boot installer.

FreeBSD sockets provide passive host-initiated streams. Binding requires root;
accepted peers must be host CID 2 and the device must report guest CID 3. The
wrapper limits sockets to 128, each socket window to 64 KiB and each RX/TX pool
to 32 buffers, reserving eight TX slots for control packets. Interrupt work runs
in bounded task batches, re-arms queues after draining and retries raced
completions. Receive/send shutdown directions and credit counters follow the
shared state machine. Payloads never enter driver diagnostics.
FreeBSD refuses send/receive buffer and low-watermark setters so generic socket
options cannot enlarge the fixed 64-KiB per-stream budget. The test-only native
probe checks those refusals, exact buffer size, 128 sockets with the 129th refused,
and complete capacity reuse after closing the first set. Presence of those
assertions is separate from a passing final-candidate machine execution.

Reset or device configuration changes stop the transport and fence every socket,
including listeners. The static driver refuses runtime detach and module unload
once parent-managed interrupts exist: FreeBSD's generic virtio API tears them
down only after the child detach callback returns. Shutdown/reset therefore
retain the fixed buffers and lock until VM disposal. Re-entry requires a new VM
boot. Hardware hot unplug and guest-initiated connections are unsupported.

The accepted-child helper validates counters before allocation, creates a child
outside listener ownership, and detaches/deallocates it if bounded response
capacity is unavailable. Only successful children join the accept queue. Its
regression executes the actual helper with socket-lifetime mocks and the shared
core under address/undefined-behavior sanitizers; it does not execute native
kernel queue ownership or scheduling.

`tools/buck2 build //:package-illumos-sdk` provides the hash-verified official OmniOS IPS sysroot;
`illumos/sdk.nix` also supplies its pinned cross compiler/linker and checks. This
is userland compilation evidence, separate from native kernel-module linkage
and native image assembly. `//:package-native-vsock-core-check` tests the actual common
wire/state implementation with generated malformed frames and transitions plus
address/undefined-behavior sanitizers; it establishes no target runtime behavior.

Illumos uses `illumos/0002-modern-virtio.patch` against the exact stock source.
It backports upstream 17789 modern/transitional support, 17856 64-bit queue
addresses, 18358 BAR caching, 18359 mutex release, 18368 notification ordering
and 18369 DMA synchronization length. The last two fixes are extracted without
the unrelated optional EVENT_IDX/MQ implementation. Original licenses and
copyright notices remain in the patch. Its SHA-256 is
`8291c3941819598d4dbd83672d5c137fce9f74cca3990ed6566a6997467e9d67`.
The virtio module ABI changes; `vioblk`, `vioif`, `vioscsi`, `vio9p` and `viorand`
all require rebuilding together, including legacy/transitional consumers.

The public `illumos/include/sys/vsock.h` defines family 40 and the same native
16-byte port/CID layout used by the Rust adapter. The private `viosock.h` asserts
those offsets. `viosock.c` owns three queues, preallocated RX/TX/event DMA and
callback subscription lifetime; `sockvsock.c` owns stream sockets, bounded receive
rings, shutdown, timeouts and application-consumed credit. It requires global-zone
system-configuration privilege and refuses outgoing connect. Control traffic
retains TX capacity; shutdown/credit notifications retry after queue backpressure.
The read-only `getsockopt(AF_VSOCK, VSOCK_SO_BUILD_ID=1)` returns a 65-byte
compiled-input token (64 hex bytes plus NUL); the socket and transport module
tokens must match. Short buffers return EMSGSIZE and writes EOPNOTSUPP.
Callbacks never hold transport locks, unsubscribe drains before replacement,
and unlocked user copies hold references and revalidate stream state.

The transport allocates its worker and all 65 DMA/chain pairs before
`virtio_init_complete` publishes `DRIVER_OK`. After activation it refuses runtime
detach and retains interrupt-visible storage until VM disposal. A late
interrupt-enable or duplicate-device failure fences sockets, disables interrupts
and drains workers while retaining an unavailable attachment. Preactivation
failure may reclaim storage. The source-extracted host harness passed 236
allocation-failure sites, both late failures, success and detach under address
and undefined-behavior sanitizers; three lifetime mutants were rejected. These
mocked checks do not establish native interrupt or DMA safety.

`0004-block-direct-budget.patch` bounds direct block requests by
`min(ring_size / (data_segments + 2), fixed_request_pool)`, clamps scatter before
DMA attributes and refuses undersized rings. Indirect requests retain one ring
descriptor each. The pinned 256-descriptor/128-data-segment case permits one
direct request. The source-extracted helper passed 265,596 generated/boundary
vectors with sanitizers. This corrects an internal capacity defect; no traced
descriptor failure or native comparison establishes it as the cause of the
earlier ZFS EIO.
Block completion must recycle the request/descriptors before notifying blkdev,
which can synchronously issue the next DMA window or queued request. The driver
caches the original result, permits immediate reuse and never touches the old
request after callback entry. Completed external transfers report submission
success after exactly one error/result callback, including polled errors;
internal requests without callbacks retain their direct error. The extracted
five-function regression passed 161 strict-C11/sanitized histories and rejected
four actual-source mutants. This is host/mock ownership evidence; corrected
native execution remains separate.

`0003-listener-reset.patch` adds an opt-in sockfs listener reset mode. Its sticky
accept failure bit occupies an unused `so_state` value; `sonode` layout and size
remain unchanged, preserving stock SCTP's embedded sonode. The wrapper opts in;
ordinary listeners retain their existing behavior. Reset/configuration change
fences all old sockets, including listeners and unbound sockets. A failed socket
cannot bind/listen again, and accepted children recheck both child and parent
fences before publication. The regression harness executes extracted patched
sockfs functions with blocked accept threads; it establishes Linux model scope,
not native kernel scheduling or DMA safety.

The illumos object check compiles the framework, all consumers, wrappers, shared
core and sockfs sources with pinned Solaris headers. It records object sizes,
digests and ELF evidence. It explicitly undefines Clang's Solaris
`_XOPEN_SOURCE=600` default: kernel syscall definitions must export ordinary
`bind`, `connect`, `getsockopt`, `recvmsg`, `sendmsg` and `sendto`, without
userland `__xnet_*` renaming. The build checks those actual object symbols and
binds the configuration file and Nix recipe hashes into the compiled input token.
Relocatable object output is not a linked kernel module.
The native module link/install layout is:

| Output | Native link inputs/dependencies | Guest path |
| --- | --- | --- |
| virtio | main, DMA, legacy and modern objects | `/kernel/misc/amd64/virtio` |
| vioblk | `-N misc/virtio -N drv/blkdev` | `/kernel/drv/amd64/vioblk` |
| vioif | `-N misc/virtio -N misc/mac` | `/kernel/drv/amd64/vioif` |
| vioscsi | `-N misc/scsi -N misc/virtio` | `/kernel/drv/amd64/vioscsi` |
| vio9p | `-N misc/virtio` | `/kernel/drv/amd64/vio9p` |
| viorand | `-N misc/kcf -N misc/virtio` | `/kernel/drv/amd64/viorand` |
| sockfs | complete `SOCK_OBJS`, `-N drv/ip` | `/kernel/fs/amd64/sockfs` |
| viosock | transport plus common core, `-N misc/virtio` | `/kernel/drv/amd64/viosock` |
| sockvsock | socket wrapper, `-N fs/sockfs -N drv/viosock` | `/kernel/socketmod/amd64/sockvsock` |

Each native link requires Solaris `ld -ztype=kmod`; GNU cross-linking does not
supply that kernel-module contract. Preserve all legacy aliases and add modern
`pci1af4,1042,p` for vioblk, `pci1af4,1041,p` for vioif, and `pci1af4,1053,p` for
viosock. Install the socket mapping `40 2 0 sockvsock` (`SOCK_STREAM` is 2 on
illumos), copy the public header to `/usr/include/sys/vsock.h`, and rebuild the
boot archive after module installation. These are assembly requirements, not a
claim that the closed image constructor performs them yet.

The object output also publishes `bin/overalls-illumos-candidate`, implemented
by `illumos/native_candidate.py`. Run it inside the matching native OmniOS
assembly guest:

```sh
python3 native_candidate.py link OBJECT_BUNDLE EXPECTED_BUILD_ID NEW_LINKED_BUNDLE
python3 native_candidate.py install ALTERNATE_ZFS_ROOT LINKED_BUNDLE EXPECTED_BUILD_ID
```

The link operation verifies all 26 object sizes/digests and their ELF headers,
then stages the verified bytes before invoking the native linker. Its receipt
records the actual nine linked module hashes, header, build ID, source receipt
hash and native linker identity. The install operation verifies that bundle
before writing, refuses the running root or its dataset, requires an exact
canonical alternate ZFS mount, and refuses symlink destinations. It preserves
legacy aliases, adds the modern aliases and socket mapping, installs the public
header and root-owned expected token, and rebuilds that root's boot archive.
It neither selects the boot environment nor enables native catalog admission.

On 2026-10-17, an earlier 26-object native link/install succeeded but its sockfs
module failed native loading because Clang renamed the kernel `bind` definition.
That result is superseded by the corrected configuration/recipe-bound build ID
`26af66ac9f0729d965918816f5132bf161a8d8a5af3bc68a7aed1f6b815e72a8`.
All 26 objects passed the syscall-symbol gate, native linkage with Solaris Link
Editors 5.11-1.1790, alternate-ZFS installation and boot-archive rebuild. The
linked receipt SHA-256 is
`5b2323d51e3ea44b76043ebfc7949d9d96cc0786be0b6320594cf90489f6bdba`.
The original boot environment was preserved. The corrected clone booted in
QEMU and a native TCP bind succeeded; all seven helper boundary tests also
passed natively under the pinned image's Python 3.12.3.
Both receipts explicitly retain `runtime_validated=false` and
`native_admission=false`. This records module assembly; complete reproducible
disk assembly, Firecracker socket transport and acceptance remain separate.
The later preallocated-taskq revision has build ID
`4b1627f10dca4964bd29eaff1d12904cc65a83d9edae6cd79a10eeebdaa807fd`.
It also passed native nine-module link/install and archive rebuild in a new
stock-root clone, with linked receipt
`f743593e7479e0e2145b58008a838d196012ed1d9b630214a8c528cd61de8f05`.
The earlier QEMU bind result remains scoped to `26af66ac`. A later diagnostic
Firecracker boot executed `4b1627f1` with a debugger-applied UART setting:
the complete image verifier and native token/CID/buffer/capacity refusals passed,
followed by malformed-length/disconnect recovery and nine exact echo sizes
through 1 MiB. That diagnostic is separate from normal persistent boot.
A subsequent clean image assembly/export passed, but its ordinary service boot
exposed stock-network and SMF-schema defects and an earlier unexplained ZFS EIO.
The corrected complete image still requires fresh normal boot and service/storage
replay.

The earlier static-lifetime/direct-budget object build is
`/nix/store/8r2lwnsi1qql51q3b23d7f5ajfpq1v5y-overalls-illumos-kernel-candidate-objects-6f87d0b5d63b957991dc9d4a01a7e6c95483282c`,
with compiled token
`985301b455d2a656b4664381b38374fec4aebfa57e2dc8185a072723092efa41`
and aggregate patch hash
`b92c2e3c7803db22ad11c9c71a3ecd8ead0d4e3187ca35eb3c32c26079155df1`.
All 26 objects and all three host-test gates passed. This exact token subsequently
passed native nine-module linkage, complete 764-entry payload installation,
archive rebuild and clean export in the final `8m1r` kit. The sealed disk hash is
`24318238ff18723fe3c984eac04475ede0d6ceb9d802aecaddd092ead70efa61`;
the native review records its exact assembly receipt. Normal boot and runtime
evidence for this disk remain separate acceptance gates.
Its first service, ordinary-transport and reset runs failed during early boot
with blank serial and Firecracker `Shutdown(GenericError)`, before fixtures or
probes. The cause is not established; the native review preserves those failures.

The completion-corrected object build is
`/nix/store/hqc4qqs55zv5byzsjbl71qx7xm8qw5aq-overalls-illumos-kernel-candidate-objects-6f87d0b5d63b957991dc9d4a01a7e6c95483282c`,
with token
`76b8c1ad4ba2e25f87768bbf8a1c55ed0f8d1b9fb973f776799c0b68eda98809`
and aggregate patch SHA256
`26aea847a4c288bb17970324c488d1624f011d02a1f67ed61b47d94b589f352b`.
All 26 objects and four host-test gates passed, followed by separate pristine
native assembly in kit `wvz8` with nine linked modules and 764 verified payload
entries. Read-only receipt extraction and clean shutdown sealed disk SHA256
`a49255bd16732be7b499ad36caab09f96df5de10fae58eedf7bae90aaffb5fc2`.
The review records exact receipts and keeps the earlier failed disk separate.
A paired direct-only QEMU diagnostic reaches console login on corrected `76b8`
under the same no-vsock settings where `9853` panics mounting root. Growth enters
maintenance in this diagnostic; Firecracker service/transport/reset acceptance
and original ZFS EIO causality remain separate. The first corrected-image
Firecracker service run stays alive but misses its 240-second first-boot
deadline, with blank serial and no kernel/service response.

The `freebsd-kernel-receipt` and `illumos-kernel-receipt` outputs remain explicitly
unavailable with zero bytes. Neither image constructor consumes the candidate or
enters the fleet catalog. Native admission requires target-native image assembly
and recorded boot, CID, malformed-input, reset, isolation and recovery tests.
Compilation, linking and symbol checks alone establish no native runtime support.
ADR-0190 governs these requirements.
