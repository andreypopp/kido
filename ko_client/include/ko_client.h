#ifndef KO_CLIENT_H
#define KO_CLIENT_H

#include <dispatch/dispatch.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The C ABI of ko_client, the client core of Kido.app. It is hand-written
 * beside ko_client/src/ffi.rs; the two change together.
 *
 * Conventions:
 *
 * Handle. ko_client_connect returns an opaque handle. The caller owns it
 * until it passes it to ko_client_close, once. A handle is not thread-safe
 * beyond that: only ko_client_close touches it.
 *
 * Caller memory. The core copies every argument that it keeps, before
 * ko_client_connect returns. It never reads a caller buffer afterwards, so
 * the caller may free or overwrite the socket path at once. `user` is the
 * one pointer that the core keeps. It is opaque to the core and is passed
 * back unchanged; the caller keeps what it names alive until the last
 * callback returned or ko_client_close returned, whichever is later.
 *
 * Core memory. The core allocates every event and string in a callback and
 * frees it when the callback returns. A pointer in an event is valid only
 * for the duration of the callback and is never freed by the caller. To keep
 * a value, the callback copies it. Nothing else crosses the ABI: no
 * function returns an owned buffer, so there is no free function.
 *
 * Threads. The core does its I/O on its own thread and never calls the
 * callback on it. Every callback runs on the dispatch queue that the caller
 * passed to ko_client_connect (pass dispatch_get_main_queue() or
 * DispatchQueue.main for the main queue), so the Swift side needs no
 * hop. Events of one handle arrive in order. The queue must be serial.
 *
 * Close. After ko_client_close returns, no new callback of that handle
 * starts, and a callback on another thread has ended; a callback that called
 * close finishes normally. Events that were queued on the dispatch queue
 * before the call are dropped without a call. ko_client_close may be called
 * on any thread, also from inside a callback of the same handle. It waits for
 * a callback of that handle that is running on another thread, and for the
 * core's I/O thread, which ends at once because close shuts down every
 * connection the core opened. It never waits for the network.
 *
 * Errors. A function returns a ko_code: KO_OK, or the reason that it did
 * nothing. Failures of the connection come later, as one KO_EVENT_FAILED
 * event with a ko_code and a UTF-8 message, and that event is the last the
 * handle delivers. The handle still needs ko_client_close. ko_code_message
 * gives a static description of a code.
 */

typedef struct ko_client ko_client;

typedef enum ko_code {
    KO_OK = 0,
    KO_ERR_ARGUMENT = 1,
    KO_ERR_NO_SERVER = 2,
    KO_ERR_IO = 3,
    KO_ERR_PROTOCOL = 4,
    KO_ERR_CLOSED = 5,
} ko_code;

enum {
    KO_EVENT_WELCOME = 1,
    KO_EVENT_LAYOUT = 2,
    KO_EVENT_FAILED = 3,
};

typedef struct ko_welcome {
    const char *client;
    const char *instance;
    uint64_t now;
} ko_welcome;

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

/* `kind` says which member of the union is set. */
typedef struct ko_event {
    int kind;
    union {
        ko_welcome welcome;
        ko_layout layout;
        ko_failure failure;
    };
} ko_event;

typedef void (*ko_callback)(void *user, const ko_event *event);

/*
 * Starts a connection to the ko server at `socket` (the path of its unix
 * socket) and returns at once. The core connects, joins as an app client,
 * and delivers KO_EVENT_WELCOME, then KO_EVENT_LAYOUT, then a KO_EVENT_LAYOUT
 * for every later change of the layout. It does not start a server and does
 * not reconnect. On a code other than KO_OK, `*out` is NULL and nothing
 * runs.
 */
ko_code ko_client_connect(const char *socket,
                          dispatch_queue_t queue,
                          ko_callback callback,
                          void *user,
                          ko_client **out);

ko_code ko_client_close(ko_client *client);

const char *ko_code_message(int code);

#ifdef __cplusplus
}
#endif

#endif
