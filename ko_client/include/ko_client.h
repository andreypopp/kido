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
 * ko_client_prompt) block until the server answered: call them off the main
 * queue.
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
 * with a delay that grows to two seconds. KO_EVENT_FAILED reports the first
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
} ko_code;

/* The result of a restore. The values equal ghostty_snapshot_restore_result_e. */
typedef enum ko_restore_result {
    KO_RESTORE_OK = 0,
    KO_RESTORE_REJECTED = 1,
    KO_RESTORE_SIZE_MISMATCH = 2,
    KO_RESTORE_HISTORY_INCOMPLETE = 3,
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
 * and never after ko_view_close returned. The terminal size must equal the
 * snapshot's: the server's size is authoritative, so the caller sizes the
 * surface from the model (the pane's cols and rows in the layout) before it
 * opens the view, and a snapshot of another size returns
 * KO_RESTORE_SIZE_MISMATCH. KO_RESTORE_HISTORY_INCOMPLETE makes the core ask
 * the server for a new full snapshot by itself. The core drops the result of a
 * restore whose snapshot a newer one replaced.
 */
typedef int (*ko_restore_fn)(void *user, const ko_snapshot *snapshot);

/*
 * What the client tells the server in its hello. `sizes_windows` says that its
 * window takes part in sizing: the windows that it shows get its size. The core
 * sends the latest size and focus again in every later hello, but this flag
 * stays.
 */
typedef struct ko_hello {
    uint16_t cols;
    uint16_t rows;
    bool focused;
    bool sizes_windows;
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
 * The model as one JSON document in a buffer: the client and instance ids, the
 * selection, the layout document (as GET /layout gives it), every pane with
 * its label (the title to show), its seen mark ("none", "running", "waiting", "done" or "failed"),
 * its row (status, variables of the server, progress) and its variables, the
 * runs, and the outline (sessions and panes in tree order with depth). It is a
 * snapshot: a later change needs a later call.
 */
ko_code ko_client_model(const ko_client *client, ko_buffer *out);

enum {
    KO_SELECT_SESSION = 1,
    KO_SELECT_WINDOW = 2,
    KO_SELECT_PANE = 3,
};

/* Moves this client to the session, window or pane named by `id`, such as "pane_3". */
ko_code ko_client_select(const ko_client *client, int kind, const char *id);

enum {
    KO_OVER_SESSION = 1,
    KO_OVER_WINDOW = 2,
    KO_DIRECTION_NEXT = 1,
    KO_DIRECTION_PREVIOUS = 2,
};

ko_code ko_client_switch(const ko_client *client, int over, int direction);

/* The size of the window. It counts only for a client that said `sizes_windows`. */
ko_code ko_client_size(const ko_client *client, uint16_t cols, uint16_t rows);

ko_code ko_client_focus(const ko_client *client, bool focused);

/*
 * The seen record: the panes that the window shows now, and whether the user
 * attends to it (the window is key and the app active). When `attending`
 * is false nothing becomes seen.
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

enum {
    KO_RUNS_LIVE = 1,
    KO_RUNS_PRESENT = 2,
    KO_RUNS_ALL = 3,
};

/* The runs as the JSON array of GET /runs. */
ko_code ko_client_runs(const ko_client *client, int show, ko_buffer *out);

/* Sends `text` to the agent pane `target`; `out` holds the JSON answer ({"via": ...}). */
ko_code ko_client_prompt(const ko_client *client,
                         const char *target,
                         const uint8_t *text,
                         size_t len,
                         ko_buffer *out);

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

enum {
    KO_INPUT_KEY = 1,
    KO_INPUT_MOUSE = 2,
    KO_INPUT_PASTE = 3,
    KO_INPUT_TEXT = 4,
};

enum {
    KO_KEY_RELEASE = 0,
    KO_KEY_PRESS = 1,
    KO_KEY_REPEAT = 2,
    KO_MOUSE_PRESS = 0,
    KO_MOUSE_RELEASE = 1,
    KO_MOUSE_MOTION = 2,
};

/* Ghostty's key code and modifier values, as the surface produces them. */
typedef struct ko_key_input {
    int action;
    uint16_t key;
    uint16_t mods;
    uint32_t unshifted; /* the codepoint of the key without Shift; 0 if none */
    const char *text;   /* NUL-terminated; "" if none */
    bool composing;
} ko_key_input;

/* button: 0 unknown, 1 left, 2 right, 3 middle, 4 to 11 the others. */
typedef struct ko_mouse_input {
    int action;
    int button;
    uint16_t col;
    uint16_t row;
    uint16_t mods;
} ko_mouse_input;

typedef struct ko_paste_input {
    const uint8_t *text; /* UTF-8 */
    size_t len;
    bool check_safe;
    bool has_id;
    uint64_t id;
} ko_paste_input;

typedef struct ko_text_input {
    const uint8_t *data; /* already encoded text for the pty */
    size_t len;
} ko_text_input;

typedef struct ko_input {
    int kind;
    union {
        ko_key_input key;
        ko_mouse_input mouse;
        ko_paste_input paste;
        ko_text_input text;
    };
} ko_input;

/* Sends one input event on the view. KO_ERR_CLOSED when the view's connection is not up. */
ko_code ko_view_input(const ko_view *view, const ko_input *input);

const char *ko_code_message(int code);

#ifdef __cplusplus
}
#endif

#endif
