#ifndef MILA_FFI_H
#define MILA_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MilaFfiStatus {
  MILA_FFI_OK = 0,
  MILA_FFI_NULL_INPUT = -1,
  MILA_FFI_INVALID_ROUTE = -2,
  MILA_FFI_OUTPUT_TOO_SMALL = -3,
  MILA_FFI_INVALID_REQUEST = -4
} MilaFfiStatus;

typedef struct MilaFfiAbiVersion {
  uint32_t major;
  uint32_t minor;
} MilaFfiAbiVersion;

typedef struct MilaRouteOutput {
  uint8_t *bytes;
  size_t capacity;
  size_t *written;
} MilaRouteOutput;

typedef struct MilaMachineActions { uint16_t bits; } MilaMachineActions;

typedef struct MilaSnapshotSummary {
  uint32_t machine_count;
  uint64_t saved_at;
} MilaSnapshotSummary;

MilaFfiStatus mila_session_command_format(const char *action, const char *machine_id, const char *request_id, MilaRouteOutput output);
int32_t mila_session_machine_action(uint64_t handle, const uint8_t *machine, size_t machine_len, const uint8_t *action, size_t action_len, const uint8_t *request_id, size_t request_id_len);
int32_t mila_session_machine_resize(uint64_t handle, const uint8_t *machine, size_t machine_len, uint32_t cpu, uint64_t memory, uint64_t disk, const uint8_t *request_id, size_t request_id_len);
int32_t mila_session_machine_create(uint64_t handle, const uint8_t *name, size_t name_len, uint32_t cpu, uint64_t memory, uint64_t disk, const uint8_t *request_id, size_t request_id_len);
MilaFfiStatus mila_snapshot_machine_actions(const uint8_t *bytes, size_t length, const char *host, uint16_t port, uint8_t has_port, uint32_t index, MilaMachineActions *out_actions);
/* Returns the ABI major version. */
uint32_t mila_ffi_version(void);
/* Writes the complete ABI version, returning MILA_FFI_NULL_INPUT when absent. */
MilaFfiStatus mila_ffi_get_version(MilaFfiAbiVersion *out_version);
/* Canonicalizes a bounded overalls:// route into caller-owned storage. */
MilaFfiStatus mila_route_format(const char *input, MilaRouteOutput output);
/* Validates a bounded trust document against its expected management host. */
MilaFfiStatus mila_trust_document_validate(const uint8_t *document, size_t length,
                                           const char *origin_host, uint64_t now);
/* Validates fetched trust, reconciles an optional pin, and writes canonical
 * JSON selected by Rust. A zero fetched length selects an unretired pin. */
MilaFfiStatus mila_trust_document_reconcile(const uint8_t *pinned, size_t pinned_length,
                                            const uint8_t *fetched, size_t fetched_length,
                                            const char *origin_host, uint64_t now,
                                            MilaRouteOutput output);
/* Validates push registration metadata; token bytes are never returned. */
MilaFfiStatus mila_push_registration_validate(uint8_t provider, uint8_t environment,
                                              const char *token, const char *app_id,
                                              const char *deployment, const char *endpoint);
/* Validates a bounded Susan push poke envelope; ciphertext is never returned. */
MilaFfiStatus mila_push_poke_validate(const uint8_t *envelope, size_t length, uint64_t now);
/* Validates bounded watch filter counts (maximum 64 combined). */
MilaFfiStatus mila_watch_validate_filters(uint16_t machine_count, uint16_t thread_count);
MilaFfiStatus mila_terminal_attach_validate(uint64_t from, uint16_t columns, uint16_t rows, uint8_t read_write);
/* Input bytes remain owned by the native host and never cross this ABI. */
MilaFfiStatus mila_terminal_input_validate(size_t length, uint8_t read_write);
MilaFfiStatus mila_terminal_resize_validate(uint16_t columns, uint16_t rows, uint8_t read_write);
/* Validates an offline snapshot for a deployment and returns safe metadata. */
MilaFfiStatus mila_snapshot_validate(const uint8_t *bytes, size_t length,
                                     const char *host, uint16_t port,
                                     uint8_t has_port, MilaSnapshotSummary *out_summary);


typedef int32_t (*MilaSessionSign)(uintptr_t context, const uint8_t *message,
                                  size_t length, uint8_t *signature64);
int32_t mila_session_connect(const uint8_t *trust, size_t trust_len,
    const uint8_t *host, size_t host_len, const uint8_t *public_key,
    size_t public_key_len, uint16_t port, uint32_t timeout_ms,
    MilaSessionSign signer, uintptr_t context, uint64_t *out_handle);
int32_t mila_session_read_machines(uint64_t handle, uint8_t more);
int32_t mila_session_ssh_keys(uint64_t handle, uint8_t *output, size_t capacity, size_t *written);
int32_t mila_session_ssh_key_revoke(uint64_t handle, const uint8_t *key, size_t key_len, const uint8_t *request, size_t request_len);
int32_t mila_session_share_mutation(uint64_t handle, const uint8_t *machine, size_t machine_len,
    const uint8_t *email, size_t email_len, const uint8_t *role, size_t role_len, uint8_t add,
    const uint8_t *request_id, size_t request_id_len);
int32_t mila_session_thread_action(uint64_t handle, const uint8_t *thread, size_t thread_len,
    const uint8_t *command, size_t command_len, const uint8_t *secondary, size_t secondary_len,
    const uint8_t *input, size_t input_len, const uint8_t *request_id, size_t request_id_len,
    uint8_t *output, size_t capacity, size_t *written);
int32_t mila_session_web_show(uint64_t handle, const uint8_t *machine, size_t machine_len,
    uint8_t *output, size_t capacity, size_t *written);
int32_t mila_session_web_set(uint64_t handle, const uint8_t *machine, size_t machine_len,
    uint16_t port, uint8_t public_access, uint64_t revision,
    const uint8_t *request_id, size_t request_id_len);
int32_t mila_session_listing(uint64_t handle, uint8_t *output, size_t capacity,
    size_t *written);
int32_t mila_session_whoami(uint64_t handle, uint8_t *output, size_t capacity,
                             size_t *written);
int32_t mila_session_close(uint64_t handle);
/* Authenticated PTY lifecycle. Buffers are caller-owned and bounded by Rust. */
MilaFfiStatus mila_session_terminal_attach(uint64_t session_handle, uint32_t columns,
                                           uint32_t rows, uint64_t *out_terminal_handle);
MilaFfiStatus mila_session_terminal_poll(uint64_t terminal_handle, uint8_t *out,
                                          size_t capacity, size_t *written);
MilaFfiStatus mila_session_terminal_input(uint64_t terminal_handle, const uint8_t *input,
                                          size_t input_len);
MilaFfiStatus mila_session_terminal_resize(uint64_t terminal_handle, uint32_t columns,
                                            uint32_t rows);
MilaFfiStatus mila_session_terminal_kill(uint64_t terminal_handle);
/* Opens or rejoins the caller's personal terminal session (`terminal new`) and
 * writes Porsche's bounded JSON receipt naming it. */
int32_t mila_session_terminal_new(uint64_t handle, const uint8_t *machine, size_t machine_len,
    const uint8_t *request_id, size_t request_id_len, uint8_t *output, size_t capacity, size_t *written);
/* Attaches a bounded PTY to one named terminal session of one machine. Porsche
 * refuses the unnamed `mila_session_terminal_attach` form. */
int32_t mila_session_terminal_attach_session(uint64_t session_handle, const uint8_t *machine,
    size_t machine_len, const uint8_t *terminal, size_t terminal_len, uint32_t columns,
    uint32_t rows, uint64_t *out_terminal_handle);

#ifdef __cplusplus
}
#endif
#endif
typedef enum MilaThreadCommandKind { MILA_THREAD_UNKNOWN = 0, MILA_THREAD_LIST = 1, MILA_THREAD_SHOW = 2, MILA_THREAD_TURNS = 3, MILA_THREAD_PROMPT = 4, MILA_THREAD_ANSWER = 5, MILA_THREAD_PLAN_APPROVE = 6, MILA_THREAD_PLAN_REVISE = 7, MILA_THREAD_MODE = 8, MILA_THREAD_READ = 9 } MilaThreadCommandKind;
MilaFfiStatus mila_thread_command_kind(const char *line, MilaThreadCommandKind *out_kind);
typedef enum MilaMachineCommandKind { MILA_MACHINE_UNKNOWN = 0, MILA_MACHINE_LIST = 1, MILA_MACHINE_SHOW = 2, MILA_MACHINE_NEW = 3, MILA_MACHINE_RESIZE = 4, MILA_MACHINE_START = 5, MILA_MACHINE_STOP = 6, MILA_MACHINE_PAUSE = 7, MILA_MACHINE_RESUME = 8, MILA_MACHINE_DELETE = 9, MILA_MACHINE_SHARE_ADD = 10, MILA_MACHINE_SHARE_REMOVE = 11, MILA_MACHINE_WEB_SHOW = 12, MILA_MACHINE_WEB_SET = 13 } MilaMachineCommandKind;
MilaFfiStatus mila_machine_command_kind(const char *line, MilaMachineCommandKind *out_kind);

