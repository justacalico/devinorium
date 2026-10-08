#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <glib/gstdio.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Single instance (the default): when a second launch forwards
  // activation to the primary process, raise the existing window instead
  // of creating a new one. With G_APPLICATION_NON_UNIQUE each launch is
  // its own process, so this only fires for in-process re-activation.
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // The app draws its own title bar in Flutter, so don't use a GTK header
  // bar on any desktop environment.
  gtk_window_set_title(window, "Devinorium");

  const gchar* assets_path = fl_dart_project_get_assets_path(project);
  g_autofree gchar* icon_path =
      g_build_filename(assets_path, "assets", "icon.png", nullptr);
  g_autoptr(GError) error = nullptr;
  if (!gtk_window_set_icon_from_file(GTK_WINDOW(window), icon_path, &error)) {
    g_warning("Failed to load window icon: %s",
              error ? error->message : "unknown error");
  }

  gtk_window_set_default_size(window, 1280, 720);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

// Whether the "multiple windows" marker file exists. Mirrors
// LocalServerManager.dataDirPath in Dart so the setting can be checked
// before this process claims the unique application name.
static gboolean multi_window_enabled() {
  const gchar* xdg = g_getenv("XDG_DATA_HOME");
  const gchar* home = g_getenv("HOME");
  if (home == nullptr) home = g_getenv("USERPROFILE");
  g_autofree gchar* dir = nullptr;
  if (xdg != nullptr && xdg[0] != '\0') {
    dir = g_build_filename(xdg, "devinorium", nullptr);
  } else if (home != nullptr && home[0] != '\0') {
    dir = g_build_filename(home, ".local", "share", "devinorium", nullptr);
  } else {
    // Dart's `??` picks the first set variable, even when it is empty.
    const gchar* user = g_getenv("USER");
    if (user == nullptr) user = g_getenv("LOGNAME");
    if (user == nullptr) user = g_getenv("USERNAME");
    if (user == nullptr) user = "shared";
    // Directory.systemTemp consults TMPDIR, then TMP, then /tmp — again
    // only unset variables fall through, a set-but-empty value is used.
    const gchar* tmp = g_getenv("TMPDIR");
    if (tmp == nullptr) tmp = g_getenv("TMP");
    if (tmp == nullptr) tmp = "/tmp";
    g_autofree gchar* dirname = g_strdup_printf("devinorium-%s", user);
    dir = g_build_filename(tmp, dirname, nullptr);
  }
  g_autofree gchar* marker = g_build_filename(dir, "multi_window", nullptr);
  return g_file_test(marker, G_FILE_TEST_IS_REGULAR);
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // G_APPLICATION_FLAGS_NONE is deprecated since GLib 2.74 and the build
  // uses -Werror, so use its replacement when the headers provide it.
#if GLIB_CHECK_VERSION(2, 74, 0)
  GApplicationFlags app_flags = G_APPLICATION_DEFAULT_FLAGS;
#else
  GApplicationFlags app_flags = G_APPLICATION_FLAGS_NONE;
#endif

  // Multiple windows enabled: give up the unique application name so every
  // launch registers independently and opens its own window.
  if (multi_window_enabled()) {
    app_flags =
        static_cast<GApplicationFlags>(app_flags | G_APPLICATION_NON_UNIQUE);
  }

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     app_flags, nullptr));
}
