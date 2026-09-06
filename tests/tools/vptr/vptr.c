// Virtual pointer for the drag tests. Hyprland implements
// zwlr_virtual_pointer_manager_v1, so a client can move the pointer and press
// buttons without a real mouse. Nothing else can drive Nook's drag: the bar
// starts a drag from its own pointer handlers, so the gesture has to be real.
//
// Usage: vptr <width> <height> [command...]
//   m <x> <y>   move the pointer to an absolute position
//   d           press the left button
//   u           release the left button
//   s <ms>      sleep
//
// With no commands it reads them from stdin, one per line, until EOF. The
// pointer device lives for as long as the process does, and destroying it drops
// hover, so a test that has to keep something hovered while it inspects the
// shell drives one long-lived process instead of many short ones.
//
// Width and height are the screen extent the coordinates are measured in.

#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct zwlr_virtual_pointer_manager_v1 *manager;
static struct wl_seat *seat;

static void handle_global(void *data, struct wl_registry *registry, uint32_t name,
                          const char *interface, uint32_t version) {
  (void)data;
  (void)version;
  if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0)
    manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
  else if (strcmp(interface, wl_seat_interface.name) == 0)
    seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
}

static void handle_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}

static const struct wl_registry_listener registry_listener = {
  .global = handle_global,
  .global_remove = handle_global_remove,
};

static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void nap(long ms) {
  struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
  nanosleep(&ts, NULL);
}

// Applies one command, given as up to three whitespace-separated tokens.
// Returns 0 on success, 2 on a command it does not know.
static int apply(struct zwlr_virtual_pointer_v1 *pointer, struct wl_display *display,
                 uint32_t extent_x, uint32_t extent_y, char **token, int count) {
  if (count >= 3 && strcmp(token[0], "m") == 0) {
    zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), (uint32_t)atoi(token[1]),
                                            (uint32_t)atoi(token[2]), extent_x, extent_y);
    zwlr_virtual_pointer_v1_frame(pointer);
  } else if (count >= 1 && (strcmp(token[0], "d") == 0 || strcmp(token[0], "u") == 0)) {
    uint32_t state = token[0][0] == 'd' ? WL_POINTER_BUTTON_STATE_PRESSED
                                        : WL_POINTER_BUTTON_STATE_RELEASED;
    zwlr_virtual_pointer_v1_button(pointer, now_ms(), BTN_LEFT, state);
    zwlr_virtual_pointer_v1_frame(pointer);
  } else if (count >= 2 && strcmp(token[0], "s") == 0) {
    wl_display_flush(display);
    nap(atol(token[1]));
    return 0;
  } else {
    fprintf(stderr, "vptr: bad command '%s'\n", token[0]);
    return 2;
  }
  wl_display_flush(display);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: vptr <width> <height> [command...]\n");
    return 2;
  }

  uint32_t extent_x = (uint32_t)atoi(argv[1]);
  uint32_t extent_y = (uint32_t)atoi(argv[2]);

  struct wl_display *display = wl_display_connect(NULL);
  if (!display) {
    fprintf(stderr, "vptr: no wayland display\n");
    return 1;
  }

  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);

  if (!manager || !seat) {
    fprintf(stderr, "vptr: compositor does not offer zwlr_virtual_pointer_manager_v1\n");
    return 1;
  }

  struct zwlr_virtual_pointer_v1 *pointer =
    zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);

  if (argc > 3) {
    for (int i = 3; i < argc; i++) {
      int span = strcmp(argv[i], "m") == 0 ? 3 : strcmp(argv[i], "s") == 0 ? 2 : 1;
      if (i + span > argc) {
        fprintf(stderr, "vptr: '%s' is missing arguments\n", argv[i]);
        return 2;
      }
      int status = apply(pointer, display, extent_x, extent_y, &argv[i], span);
      if (status) return status;
      i += span - 1;
    }
  } else {
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
      char *token[3];
      int count = 0;
      for (char *word = strtok(line, " \t\r\n"); word && count < 3; word = strtok(NULL, " \t\r\n"))
        token[count++] = word;
      if (count == 0) continue;
      int status = apply(pointer, display, extent_x, extent_y, token, count);
      if (status) return status;
    }
  }

  wl_display_roundtrip(display);
  zwlr_virtual_pointer_v1_destroy(pointer);
  wl_display_disconnect(display);
  return 0;
}
