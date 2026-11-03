#ifndef KO_CLIENT_H
#define KO_CLIENT_H

#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The C ABI of ko_client, the client core of Kido.app. It is hand-written
 * beside ko_client/src/ffi.rs; the two change together.
 *
 * Handles. ko_client_connect returns a client handle. ko_view_open returns a
 * view handle. The caller owns each until it passes it to the matching close
 * call, once. Every call on a handle may run on any thread, but no call on a
 * handle may start while, or after, its close call runs. Close the views of
 * a client before the client; a client close also ends every view that is
 * still open, and the view handle then only needs ko_view_close.
 *
 * Caller memory. The core copies every argument that it keeps, before the
 * call returns. It never reads a caller buffer afterwards. `user` pointers
 * are the one thing that the core keeps. They are opaque to the core and
 * are passed back unchanged; the caller keeps what they name alive until the
 * last callback returned or the matching close call returned, whichever is
 * later.
 *
 * Core memory. A pointer in an event or in a ko_snapshot is valid only for
 * the duration of the callback and is never freed by the caller. To keep a
 * value, the callback copies it. Data that the caller must keep crosses as a
 * ko_buffer: the call fills it, the caller owns it, and ko_buffer_free
 * frees it, once. Never free it with free(). ko_buffer_free zeroes the
 * struct, so a second call on the same struct frees nothing.
 *
 * Threads. The core does its I/O on its own thread and never calls a
 * callback on it. Every ko_callback runs on the dispatch queue that the
 * caller passed to ko_client_connect (pass dispatch_get_main_queue() for
 * the main queue). Events of one client arrive in order. The queue must be
 * serial. A ko_restore_fn and a ko_feed_fn run on the decoder thread of their
 * view: one thread for each view, which is neither the queue nor the core's
 * I/O thread. The thread runs one of them at a time, in the order of the
 * server's stream, so a restore and the bytes after it never overlap and the
 * bytes of an older snapshot never follow a newer restore. The surface may
 * be fed from that thread only; the caller's queue plays no part in it. The
 * calls that return a ko_buffer (ko_client_put_layout, ko_client_runs,
 * ko_client_prompt, ko_client_prompt_resolve, ko_client_delete, ko_client_edit, ko_client_image) and ko_client_launch, ko_client_stop_server and ko_client_probe block
 * until the server answered: call them off the main queue.
 *
 * Close. After ko_client_close or ko_view_close returns, no callback of that
 * handle starts, and a callback on another thread has ended. Events that were
 * queued on the dispatch queue before the call are dropped without a call.
 * ko_view_close also waits for the restore or the feed of its view that is
 * running, after it made that restore's blocked reads fail. ko_client_close
 * does the same for every view that was not closed yet, also one that the
 * server ended, and cancels a blocked call on another thread, also one that
 * is writing a request, which then returns KO_ERR_CLOSED. Either may be called from
 * inside an event callback of the same client. Neither may be called from
 * inside a ko_restore_fn.
 *
 * Reconnect. The core connects again by itself after the connection ended,
 * with a delay that grows to two seconds, except after KO_EVENT_MISMATCH. KO_EVENT_FAILED reports the first
 * failure of an outage only. A new KO_EVENT_WELCOME ends the outage. Its
 * `fresh` is true when the server is another process than the one before
 * (another `instance`): every view is then closed with KO_EVENT_VIEW_CLOSED,
 * and the caller reads the model and opens the views again. Otherwise the
 * views open again by themselves at the offset of the last bytes that were
 * delivered, and the caller's surfaces stay valid.
 *
 * Errors. A function returns a ko_code: KO_OK, or the reason that it did
 * nothing. A call that returns a ko_buffer and fails fills the buffer with
 * the UTF-8 text of the error when there is one. ko_code_message gives a
 * static description of a code.
 */

typedef struct ko_client ko_client;
typedef struct ko_view ko_view;

typedef enum ko_code {
    KO_OK = 0,
    KO_ERR_ARGUMENT = 1,
    KO_ERR_NO_SERVER = 2,
    KO_ERR_IO = 3,
    KO_ERR_PROTOCOL = 4,
    KO_ERR_CLOSED = 5,
    KO_ERR_CONFLICT = 6,
    KO_ERR_NOT_FOUND = 7,
    KO_ERR_INVALID = 8,
    KO_ERR_REFUSED = 9,
    KO_ERR_GONE = 10,
    KO_ERR_UNKNOWN = 11, /* the outcome is not known: an error that the core does not know, or a
                          * ko_client_prompt that may have reached its agent */
    KO_ERR_PROTOCOL_MISMATCH = 12,
    KO_ERR_VT_MISMATCH = 13,
} ko_code;

/* The result of a restore. */
typedef enum __attribute__((enum_extensibility(closed))) ko_restore_result {
    KO_RESTORE_OK = 0,
    KO_RESTORE_REJECTED = 1,
    KO_RESTORE_HISTORY_INCOMPLETE = 2,
} ko_restore_result;

enum {
    KO_EVENT_WELCOME = 1,
    KO_EVENT_LAYOUT = 2,
    KO_EVENT_FAILED = 3,
    KO_EVENT_MODEL = 4,
    KO_EVENT_SELECTED = 5,
    KO_EVENT_ALERT = 6,
    KO_EVENT_VIEW_RESTORED = 7,
    KO_EVENT_VIEW_CLOSED = 8,
    KO_EVENT_MISMATCH = 9,
    KO_EVENT_CLIPBOARD_WRITE = 10,
    KO_EVENT_CLIPBOARD_READ = 11,
};

typedef struct ko_welcome {
    const char *client;
    const char *instance;
    uint64_t now;
    bool fresh;
} ko_welcome;

/* The layout document changed. Read the model for its content. */
typedef struct ko_layout {
    uint64_t revision;
    uint32_t sessions;
    uint32_t windows;
    uint32_t panes;
} ko_layout;

typedef struct ko_failure {
    ko_code code;
    const char *message;
} ko_failure;

/* This client's selection moved. A member is NULL when the selection lacks it. */
typedef struct ko_selected {
    const char *session;
    const char *window;
    const char *pane;
} ko_selected;

enum {
    KO_ALERT_BELL = 1,
    KO_ALERT_NOTIFY = 2,
};

typedef struct ko_alert {
    int kind;
    const char *pane;
    const char *title; /* NULL when absent */
    const char *body;  /* NULL for a bell */
} ko_alert;

enum {
    KO_CLIPBOARD_STANDARD = 1,
    KO_CLIPBOARD_SELECTION = 2,
    KO_CLIPBOARD_PRIMARY = 3,
};

/* One representation of a clipboard: its MIME type and its bytes. */
typedef struct ko_clipboard_content {
    const char *mime;
    const uint8_t *data;
    size_t len;
} ko_clipboard_content;

/*
 * A program wrote the clipboard `location` of `pane`. Every client whose window shows the pane gets
 * the event, and applies its own consent. `contents` is valid during the callback.
 */
typedef struct ko_clipboard_write {
    const char *pane;
    int location;
    const ko_clipboard_content *contents;
    size_t count;
} ko_clipboard_write;

/*
 * A program of `pane` asks to read the clipboard `location`, as the MIME types `mimes` (`list` asks
 * which types the clipboard holds: answer with `available`). The server picked this client to
 * answer: it must call ko_client_clipboard_answer with `id`, within 8 seconds, or the read is
 * refused. An answer that lands later is ignored.
 */
typedef struct ko_clipboard_read {
    const char *pane;
    uint64_t id;
    int location;
    const char *const *mimes;
    size_t count;
    bool list;
} ko_clipboard_read;

/* The protocol version, the terminal revision and the build of a ko binary. */
typedef struct ko_version {
    const char *protocol;
    const char *vt;
    const char *build;
} ko_version;

/*
 * The server answers with another protocol major (`code` is
 * KO_ERR_PROTOCOL_MISMATCH) or another terminal revision (KO_ERR_VT_MISMATCH).
 * The core stops: it does not connect again, and no KO_EVENT_FAILED follows.
 * Close the client and start a matching server.
 */
typedef struct ko_mismatch {
    ko_code code;
    ko_version server;
    ko_version own;
} ko_mismatch;

/*
 * The members below carry the `user` pointer that the caller gave to
 * ko_view_open in `view`.
 */
typedef struct ko_view_restored {
    void *view;
    uint64_t generation;
    ko_restore_result result;
} ko_view_restored;

/* The view is over: its connection failed, or the server restarted. */
typedef struct ko_view_closed {
    void *view;
    ko_code code;
    const char *message;
} ko_view_closed;

/*
 * `kind` says which member of the union is set. KO_EVENT_MODEL, which says that
 * a pane's state, a title or a run changed, has none: read the model. The core
 * posts it again only after the caller's queue took the last one.
 */
typedef struct ko_event {
    int kind;
    union {
        ko_welcome welcome;
        ko_layout layout;
        ko_failure failure;
        ko_selected selected;
        ko_alert alert;
        ko_view_restored view_restored;
        ko_view_closed view_closed;
        ko_mismatch mismatch;
        ko_clipboard_write clipboard_write;
        ko_clipboard_read clipboard_read;
    };
} ko_event;

typedef void (*ko_callback)(void *user, const ko_event *event);

typedef struct ko_buffer {
    uint8_t *data;
    size_t len;
    size_t cap;
} ko_buffer;

/*
 * Frees the data of a buffer that a call filled, and zeroes the struct.
 * A zeroed struct, or NULL, frees nothing.
 */
void ko_buffer_free(ko_buffer *buffer);

/*
 * The pull interface of one snapshot, in the shape of ghostty_snapshot_read_fn:
 * it fills up to `capacity` bytes and sets `*count`; a count of 0 is the end.
 * It blocks until bytes arrived. It returns false when the snapshot was
 * cancelled (a newer snapshot began, or the view or the client closes) or the
 * connection ended; the restore then stops with KO_RESTORE_REJECTED. The core
 * never holds a whole snapshot: it stops reading the connection while a few
 * MiB are unread, so a slow restore slows the server's writes.
 */
typedef bool (*ko_read_fn)(void *reader, uint8_t *buffer, size_t capacity, size_t *count);

/*
 * One snapshot to restore, valid until the restore returns. `history` says
 * whether the stream runs to its end (a full snapshot) or ends after the
 * screen. `continuation_max_bytes` is the server's limit for a sequence that
 * the snapshot cut open (from its Welcome); pass it on unchanged.
 * `generation` counts the snapshots of the view from 1. `offset` is the pty
 * offset that the snapshot stands at: the bytes that follow it start there.
 */
typedef struct ko_snapshot {
    ko_read_fn read;
    void *reader;
    bool history;
    size_t continuation_max_bytes;
    uint64_t generation;
    uint64_t offset;
} ko_snapshot;

/*
 * Decodes the snapshot into the view's surface and returns a ko_restore_result.
 * It runs on the decoder thread, never concurrently with itself for one view,
 * and never after ko_view_close returned. The server's size is authoritative:
 * the surface takes the snapshot's size, and the KO_FEED_RESIZE items that
 * follow bring it forward; the caller never sizes the surface from the model.
 * KO_RESTORE_HISTORY_INCOMPLETE makes the core ask
 * the server for a new full snapshot by itself. The core drops the result of a
 * restore whose snapshot a newer one replaced.
 */
typedef int (*ko_restore_fn)(void *user, const ko_snapshot *snapshot);

/*
 * What the client tells the server in its hello. `sizes_windows` says that its
 * window takes part in sizing: the windows that it shows get its size. The core
 * sends the latest size and focus again in every later hello, but this flag
 * stays. `name` is NUL-terminated and tells the server's log which client
 * this is; NULL means "app".
 */
typedef struct ko_hello {
    uint16_t cols;
    uint16_t rows;
    bool focused;
    bool sizes_windows;
    const char *name;
} ko_hello;

/*
 * One step of the stream after a snapshot, valid until the feed returns. For
 * KO_FEED_BYTES the pty output at `offset`; for KO_FEED_RESIZE the new size of
 * the terminal, which the surface takes at once; KO_FEED_DEAD says that the
 * pane's program ended. The core drops what follows a restore that did not
 * return KO_RESTORE_OK, and what a newer snapshot made stale, and reads the
 * connection no further while a few MiB wait for the surface.
 */
enum {
    KO_FEED_BYTES = 1,
    KO_FEED_RESIZE = 2,
    KO_FEED_DEAD = 3,
};

typedef struct ko_feed {
    int kind;
    uint64_t offset;
    const uint8_t *data;
    size_t len;
    uint16_t cols;
    uint16_t rows;
} ko_feed;

typedef void (*ko_feed_fn)(void *user, const ko_feed *feed);

/*
 * Starts a connection to the ko server at `socket` (the path of its unix
 * socket) and returns at once. The core joins as an app client and delivers
 * KO_EVENT_WELCOME, KO_EVENT_LAYOUT, and then one event for every change of
 * the model. A layout event also reports a change of a window's focus: the
 * revision is then the same as before. It does not start a server. `hello` may
 * be NULL: 80 by 24, no focus, no part in sizing. On a code other than KO_OK,
 * `*out` is NULL and nothing runs.
 */
ko_code ko_client_connect(const char *socket,
                          dispatch_queue_t queue,
                          ko_callback callback,
                          void *user,
                          const ko_hello *hello,
                          ko_client **out);

ko_code ko_client_close(ko_client *client);

/*
 * Starts the ko server of the state directory `dir` with the executable `executable`
 * (`ko server --server dir`), unless one runs there, and returns the path of its unix
 * socket in `socket`. It waits up to five seconds. On a code other than KO_OK `socket`
 * holds the text of the error. It blocks: call it off the main queue. ko_client_connect
 * never starts a server.
 */
ko_code ko_client_launch(const char *dir, const char *executable, ko_buffer *socket);

/*
 * Stops the server of the state directory `dir` and waits until it has ended. On a
 * code other than KO_OK `error` (which may be NULL) holds the text of the error. It
 * blocks: call it off the main queue.
 */
ko_code ko_client_stop_server(const char *dir, ko_buffer *error);

/* The protocol, terminal revision and build of this core; the strings are static. */
ko_code ko_client_version(ko_version *out);

/*
 * Asks the server at the unix socket `socket` for its version (GET /version) and waits up to
 * `within_ms` milliseconds for each read. `out` holds the server's version as JSON
 * ({"protocol", "vt", "build"}) on KO_OK, KO_ERR_PROTOCOL_MISMATCH and KO_ERR_VT_MISMATCH,
 * and the text of the error on any other code: KO_ERR_NO_SERVER (no socket, or nothing listens),
 * KO_ERR_CLOSED (the connection ended before the answer: a forward whose remote socket does not
 * exist), KO_ERR_IO, KO_ERR_PROTOCOL (an answer that is not a version). It never connects as a
 * client and starts nothing. It blocks: call it off the main queue.
 */
ko_code ko_client_probe(const char *socket, uint32_t within_ms, ko_buffer *out);

/*
 * What a finished ssh command printed and how it ended: `status` is the exit status, or the
 * signal number when `signaled`. The buffers are not NUL-terminated and may be NULL when empty.
 */
typedef struct ko_ssh_run {
    int status;
    bool signaled;
    const uint8_t *stdout_data;
    size_t stdout_len;
    const uint8_t *stderr_data;
    size_t stderr_len;
} ko_ssh_run;

/*
 * Classifies `ssh HOST ko server --print-socket`. KO_OK: `out` is the remote socket path.
 * Otherwise `out` is the text to show: KO_ERR_NOT_FOUND (no ko on the PATH of ssh commands),
 * KO_ERR_IO (ssh itself failed), KO_ERR_INVALID (a path that is not one, or another failure
 * of the command). Pure: it starts nothing.
 */
ko_code ko_remote_socket(const char *host, const ko_ssh_run *run, ko_buffer *out);

/*
 * The text for a forward that leads nowhere. `remote_answers` is whether `ko api /version` ran on
 * the host: true means the host refuses unix-socket forwarding (KO_ERR_REFUSED), false that no
 * server runs there (KO_ERR_NO_SERVER). `out` holds the text. Pure.
 */
ko_code ko_remote_unreachable(const char *host, bool remote_answers, ko_buffer *out);

/*
 * The model as one JSON document in a buffer: the client and instance ids, the
 * selection, the layout document and its revision (GET /layout without its panes), every pane with
 * its label (the title to show), its seen mark ("none", "running", "waiting", "done" or "failed"),
 * its row (status, variables of the server, progress, and its run if it has one) and its variables, and the
 * outline (sessions and panes in tree order with depth). It is a
 * snapshot: a later change needs a later call.
 * share/ko/client-model.json is the schema of the document (ModelJson); its
 * references name the components of share/ko/openapi.json.
 */
ko_code ko_client_model(const ko_client *client, ko_buffer *out);

enum {
    KO_SELECT_SESSION = 1,
    KO_SELECT_WINDOW = 2,
    KO_SELECT_PANE = 3,
};

/*
 * Moves this client to the session, window or pane named by `id`, such as "pane_3". The server
 * answers each select with KO_EVENT_SELECTED; KO_ERR_NOT_FOUND is a pane that the model's layout
 * does not have.
 */
ko_code ko_client_select(const ko_client *client, int kind, const char *id);

enum {
    KO_OVER_SESSION = 1,
    KO_OVER_WINDOW = 2,
    KO_DIRECTION_NEXT = 1,
    KO_DIRECTION_PREVIOUS = 2,
};

ko_code ko_client_switch(const ko_client *client, int over, int direction);

/*
 * The size of the window, and the pixel size of a cell for a program's size queries (0 and 0 when
 * unknown). It counts only for a client that said `sizes_windows`.
 */
ko_code ko_client_size(const ko_client *client, uint16_t cols, uint16_t rows, uint16_t cell_width, uint16_t cell_height);

ko_code ko_client_focus(const ko_client *client, bool focused);

/*
 * Answers the clipboard read `id` of a KO_EVENT_CLIPBOARD_READ. `contents` NULL refuses the read;
 * an array (also of `count` 0) answers it with exactly those representations, and `available`
 * (NULL or `available_count` strings) names the types the clipboard holds, for a `list` read. The call copies them
 * and returns at once. An answer over the server's clipboard budget (every name and every byte
 * together) is sent as a refusal. A read that the server already ended (an answer that came too late, another
 * answerer) is ignored by the server. KO_ERR_CLOSED when the connection is not up.
 */
ko_code ko_client_clipboard_answer(const ko_client *client,
                                   uint64_t id,
                                   const ko_clipboard_content *contents,
                                   size_t count,
                                   const char *const *available,
                                   size_t available_count);

/* The server's limits that a mirror must share. KO_ERR_CLOSED before the first welcome. */
typedef struct ko_limits {
    uint64_t kitty_images_max_bytes;
} ko_limits;

ko_code ko_client_limits(const ko_client *client, ko_limits *out);

enum {
    KO_PIXELS_RGB = 1,
    KO_PIXELS_RGBA = 2,
    KO_PIXELS_GRAY_ALPHA = 3,
    KO_PIXELS_GRAY = 4,
};

/*
 * One frame of an image of a pane (GET /panes/P/images/I/frames/N?generation=G, protocol.md
 * section 5). `shm_name` is a NUL-terminated name when the reply named a shared memory object
 * (`length` bytes, mapped read-only by the caller, never unlinked), and empty when the pixels are
 * `body`, which the caller frees with ko_buffer_free. On a failure `body` holds the text of the
 * error and the other members are zero. Initialize the struct to zero before the call.
 */
typedef struct ko_image {
    int format;
    uint32_t width;
    uint32_t height;
    uint64_t generation;
    uint32_t gap_ms;
    uint32_t frames;
    uint64_t length;
    char shm_name[32];
    ko_buffer body;
} ko_image;

/*
 * Fetches one frame on a new connection, parallel with any other call. `accept_shm` asks for a
 * shared memory object instead of a body: only a client of the server's own machine may. KO_ERR_NOT_FOUND:
 * the image was evicted, the frame does not exist or the generation moved on. It blocks:
 * call it off the main queue.
 */
ko_code ko_client_image(const ko_client *client,
                        const char *pane,
                        uint32_t image,
                        uint32_t frame,
                        uint64_t generation,
                        bool accept_shm,
                        ko_image *out);

/*
 * The seen record: the panes that the window shows now, and whether the user
 * attends to it (the window is key and the app active). When `attending`
 * is false nothing becomes seen. The core keeps them until the next call and
 * marks each later outcome of a shown pane seen as it arrives; call it when
 * they change. A mark that the call changes posts KO_EVENT_MODEL.
 */
ko_code ko_client_observe(const ko_client *client,
                          const char *const *panes,
                          size_t count,
                          bool attending);

/*
 * Replaces the layout if it still has the revision that the edit started from.
 * `document` is JSON: {"revision": N, "layout": {...}} with the draft layout
 * of the protocol (a new session or window has no id, a new pane is {"new":
 * {...}}); a document without a revision is KO_ERR_ARGUMENT. It is sent once.
 * On KO_OK `out` holds the new normalized document as JSON. When the layout
 * has changed, the result is KO_ERR_CONFLICT and `out` holds the newer
 * document: the caller applies its edit to that one and sends it again.
 */
ko_code ko_client_put_layout(const ko_client *client,
                             const uint8_t *document,
                             size_t len,
                             ko_buffer *out);

/*
 * Applies one edit to the layout and sends it, in the core: `edit` is the JSON of one `Edit` of
 * share/ko/client-model.json. The core starts from the layout of its model; when the layout has
 * changed, it applies the edit again to the newer document, up to eight times, so no
 * KO_ERR_CONFLICT reaches the caller except when the layout keeps changing. On KO_OK `out` holds the
 * JSON of `Edited`: the new normalized document and the session, window or pane that the edit made.
 * KO_ERR_NOT_FOUND names in `out` an id that the edit needs and the
 * layout no longer has; KO_ERR_INVALID gives the reason; KO_ERR_ARGUMENT is an edit that does not
 * decode. It blocks until the server answered: call it off the main queue.
 */
ko_code ko_client_edit(const ko_client *client,
                       const uint8_t *edit,
                       size_t len,
                       ko_buffer *out);

enum {
    KO_RUNS_LIVE = 1,
    KO_RUNS_PRESENT = 2,
    KO_RUNS_ALL = 3,
};

/* The runs as the JSON array of GET /runs. */
ko_code ko_client_runs(const ko_client *client, int show, ko_buffer *out);

/*
 * The agents that a prompt from the pane `caller` can reach: `out` holds the JSON array of
 * Candidate. Those of the caller's window come alone when it has any, or always with
 * `window_only`; else those of its session.
 */
ko_code ko_client_prompt_resolve(const ko_client *client,
                                 const char *caller,
                                 bool window_only,
                                 ko_buffer *out);

/*
 * Sends `text` from the pane `caller` to the agent pane `target`, which must be one of its
 * candidates; `out` holds the JSON answer ({"via": ...}). KO_ERR_UNKNOWN: the send failed
 * partway, or no answer came after the request was written, so the text may have arrived.
 */
ko_code ko_client_prompt(const ko_client *client,
                         const char *caller,
                         const char *target,
                         const uint8_t *text,
                         size_t len,
                         ko_buffer *out);

enum {
    KO_DELETE_PANE = 1,
    KO_DELETE_WINDOW = 2,
    KO_DELETE_SESSION = 3,
};

/*
 * Closes the pane, window or session named by `id`, such as "window_2". The server
 * ends the processes in it. It blocks until the server answered: call it off the main
 * queue. On a code other than KO_OK, `out` holds the text of the error.
 */
ko_code ko_client_delete(const ko_client *client, int kind, const char *id, ko_buffer *out);

/*
 * Opens a view of the pane named by `pane` ("pane_3") and returns at once. The
 * view begins with a snapshot (full if `history`), which the core streams to
 * `restore`, and goes on with the bytes and resizes that it gives to `feed`.
 * KO_EVENT_VIEW_RESTORED reports each restore on the caller's queue. A failure
 * arrives later as KO_EVENT_VIEW_CLOSED.
 */
ko_code ko_view_open(const ko_client *client,
                     const char *pane,
                     bool history,
                     ko_restore_fn restore,
                     ko_feed_fn feed,
                     void *user,
                     ko_view **out);

ko_code ko_view_close(ko_view *view);

/* Asks for a new snapshot. KO_ERR_CLOSED when the view's connection is not up. */
ko_code ko_view_resync(const ko_view *view, bool history);

/*
 * Sends bytes to the pane's program, as the surface encoded them (its io_write_cb).
 * KO_ERR_CLOSED when the view's connection is not up.
 */
ko_code ko_view_input(const ko_view *view, const uint8_t *data, size_t len);

const char *ko_code_message(int code);

#ifdef __cplusplus
}
#endif

#endif
