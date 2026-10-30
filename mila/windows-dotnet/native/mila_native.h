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

typedef enum MilaWatchEventKind {
  MILA_WATCH_UNKNOWN = 0,
  MILA_WATCHING = 1,
  MILA_HEARTBEAT = 2,
  MILA_MACHINE_CHANGED = 3,
  MILA_TERMINAL_SESSIONS_CHANGED = 4,
  MILA_THREAD_CHANGED = 5,
  MILA_RESYNC = 6,
  MILA_SESSION = 7
} MilaWatchEventKind;

typedef struct MilaFfiAbiVersion {
  uint32_t major;
  uint32_t minor;
} MilaFfiAbiVersion;

typedef struct MilaRouteOutput {
  uint8_t *bytes;
  size_t capacity;
  size_t *written;
} MilaRouteOutput;

/* Returns the ABI major version. */
uint32_t mila_ffi_version(void);
/* Writes the complete ABI version, returning MILA_FFI_NULL_INPUT when absent. */
MilaFfiStatus mila_ffi_get_version(MilaFfiAbiVersion *out_version);
/* Canonicalizes a bounded overalls:// route into caller-owned storage. */
MilaFfiStatus mila_route_format(const char *input, MilaRouteOutput output);
/* Validates fetched trust, reconciles an optional pin, and writes canonical
 * JSON selected by Rust. A zero fetched length selects an unretired pin. */
MilaFfiStatus mila_trust_document_reconcile(const uint8_t *pinned, size_t pinned_length,
                                            const uint8_t *fetched, size_t fetched_length,
                                            const char *origin_host, uint64_t now,
                                            MilaRouteOutput output);
/* Validates PTY dimensions and read/write mode before opening a terminal. */
MilaFfiStatus mila_terminal_validate(uint16_t columns, uint16_t rows,
                                     uint8_t read_write);
typedef enum MilaThreadCommandKind { MILA_THREAD_UNKNOWN = 0, MILA_THREAD_LIST = 1, MILA_THREAD_SHOW = 2, MILA_THREAD_TURNS = 3, MILA_THREAD_PROMPT = 4, MILA_THREAD_ANSWER = 5, MILA_THREAD_PLAN_APPROVE = 6, MILA_THREAD_PLAN_REVISE = 7, MILA_THREAD_MODE = 8, MILA_THREAD_READ = 9 } MilaThreadCommandKind;
MilaFfiStatus mila_thread_command_kind(const char *line, MilaThreadCommandKind *out_kind);
typedef enum MilaMachineCommandKind { MILA_MACHINE_UNKNOWN = 0, MILA_MACHINE_LIST = 1, MILA_MACHINE_SHOW = 2, MILA_MACHINE_NEW = 3, MILA_MACHINE_RESIZE = 4, MILA_MACHINE_START = 5, MILA_MACHINE_STOP = 6, MILA_MACHINE_PAUSE = 7, MILA_MACHINE_RESUME = 8, MILA_MACHINE_DELETE = 9, MILA_MACHINE_SHARE_ADD = 10, MILA_MACHINE_SHARE_REMOVE = 11, MILA_MACHINE_WEB_SHOW = 12, MILA_MACHINE_WEB_SET = 13 } MilaMachineCommandKind;
MilaFfiStatus mila_machine_command_kind(const char *line, MilaMachineCommandKind *out_kind);

/* Authenticated session mutation. Inputs are bounded UTF-8 and are never shell
 * interpreted by the native boundary; the Rust session owns command creation. */
int32_t mila_session_machine_action(uint64_t handle, const uint8_t *machine,
                                    size_t machine_len, const uint8_t *action,
                                    size_t action_len, const uint8_t *request_id,
                                    size_t request_id_len);
/* Executes one authenticated bounded thread operation and writes JSON output. */
int32_t mila_session_thread_action(uint64_t handle, const uint8_t *thread,
                                   size_t thread_len, const uint8_t *command,
                                   size_t command_len, const uint8_t *secondary,
                                   size_t secondary_len, const uint8_t *input,
                                   size_t input_len, const uint8_t *request_id,
                                   size_t request_id_len, uint8_t *output,
                                   size_t capacity, size_t *written);
MilaFfiStatus mila_terminal_attach_validate(uint64_t from, uint16_t columns,
                                           uint16_t rows, uint8_t read_write);
MilaFfiStatus mila_terminal_input_validate(size_t length, uint8_t read_write);
MilaFfiStatus mila_terminal_resize_validate(uint16_t columns, uint16_t rows,
                                            uint8_t read_write);
/* Authenticated PTY lifecycle. Handles are opaque and generation-bound. */
/* Opens or rejoins the caller's terminal session (`terminal new`); the JSON
 * receipt's result.session_id names the session for attach_session. */
MilaFfiStatus mila_session_terminal_new(uint64_t handle, const uint8_t *machine, size_t machine_len,
                                        const uint8_t *request_id, size_t request_id_len,
                                        uint8_t *output, size_t capacity, size_t *written);
/* Attaches a bounded PTY to one named terminal session. Porsche refuses
 * unnamed attach, so the Windows client no longer uses
 * mila_session_terminal_attach. */
MilaFfiStatus mila_session_terminal_attach_session(uint64_t session_handle, const uint8_t *machine,
                                                   size_t machine_len, const uint8_t *terminal,
                                                   size_t terminal_len, uint32_t columns,
                                                   uint32_t rows, uint64_t *out_terminal_handle);
/* Copies {"error": CODE|null} for the session's most recent refused command. */
MilaFfiStatus mila_session_last_refusal(uint64_t handle, uint8_t *output, size_t capacity,
                                        size_t *written);
MilaFfiStatus mila_session_terminal_poll(uint64_t terminal_handle, uint8_t *output,
                                         size_t capacity, size_t *written);
MilaFfiStatus mila_session_terminal_input(uint64_t terminal_handle, const uint8_t *input,
                                          size_t input_length);
MilaFfiStatus mila_session_terminal_resize(uint64_t terminal_handle, uint32_t columns,
                                           uint32_t rows);
MilaFfiStatus mila_session_terminal_kill(uint64_t terminal_handle);
typedef enum MilaTerminalReadEvent { MILA_TERMINAL_DATA = 0, MILA_TERMINAL_IDLE = 1, MILA_TERMINAL_CLOSED = 2 } MilaTerminalReadEvent;
/* Polls one chunk and classifies it as data, idle (still open) or closed; a lost
 * transport returns the session transport status instead. */
int32_t mila_session_terminal_read(uint64_t terminal_handle, uint8_t *output,
                                   size_t capacity, size_t *written,
                                   MilaTerminalReadEvent *out_event);
/* Returns the bounded `whoami --json` envelope, including approval_required. */
int32_t mila_session_whoami(uint64_t handle, uint8_t *output, size_t capacity,
                            size_t *written);
/* Validates Susan's key reply and registers this device through Porsche; the push
 * key is sent on stdin only. platform: 0=iOS 1=Android 2=macOS 3=Windows. */
int32_t mila_session_device_register(uint64_t handle, uint8_t platform,
                                     const uint8_t *susan_reply, size_t susan_reply_len,
                                     const uint8_t *enc_pubkey, size_t enc_pubkey_len,
                                     const uint8_t *label, size_t label_len, uint64_t now,
                                     uint8_t *output, size_t capacity, size_t *written);
/* Decodes one bounded watch line and returns only its event tag. */
MilaFfiStatus mila_watch_event_kind(const uint8_t *line, size_t length,
                                    MilaWatchEventKind *out_kind);
MilaFfiStatus mila_push_poke_validate(const uint8_t *envelope, size_t length,
                                      uint64_t now);
MilaFfiStatus mila_push_registration_validate(uint8_t provider, uint8_t environment,
                                              const char *token, const char *app_id,
                                              const char *deployment, const char *endpoint);

/* Encodes Susan's closed key-issuance body after push registration validation. */
MilaFfiStatus mila_push_key_request_encode(uint8_t provider, uint8_t environment,
                                           const char *token, const char *app_id,
                                           const char *deployment, const char *endpoint,
                                           MilaRouteOutput output);

#ifdef __cplusplus
}
#endif
#endif
