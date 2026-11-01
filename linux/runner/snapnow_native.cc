#include "snapnow_native.h"

#include <gtk/gtk.h>
#include <glib.h>

static const char* kChannel = "snaplite/native";
static const char* kGroup = "prefs";

// ---- Prefs: a small ini file in the user config dir (mirrors the macOS UserDefaults the app reads) ----

static GKeyFile* g_prefs = nullptr;

static gchar* prefs_path() {
  gchar* dir = g_build_filename(g_get_user_config_dir(), "snapnow", nullptr);
  g_mkdir_with_parents(dir, 0755);
  gchar* path = g_build_filename(dir, "prefs.ini", nullptr);
  g_free(dir);
  return path;
}

static void prefs_load() {
  if (g_prefs) return;
  g_prefs = g_key_file_new();
  gchar* path = prefs_path();
  g_key_file_load_from_file(g_prefs, path, G_KEY_FILE_NONE, nullptr);
  g_free(path);
}

static void prefs_save() {
  gchar* path = prefs_path();
  g_key_file_save_to_file(g_prefs, path, nullptr);
  g_free(path);
}

static const gchar* str_arg(FlValue* args, const char* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return nullptr;
  return fl_value_get_string(v);
}

static FlMethodResponse* ok_null() {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  prefs_load();

  if (g_strcmp0(method, "getBool") == 0) {
    const gchar* key = str_arg(args, "key");
    if (key && g_key_file_has_key(g_prefs, kGroup, key, nullptr)) {
      gboolean b = g_key_file_get_boolean(g_prefs, kGroup, key, nullptr);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(b)));
    } else {
      response = ok_null();
    }
  } else if (g_strcmp0(method, "setBool") == 0) {
    const gchar* key = str_arg(args, "key");
    FlValue* v = args ? fl_value_lookup_string(args, "value") : nullptr;
    if (key && v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL) {
      g_key_file_set_boolean(g_prefs, kGroup, key, fl_value_get_bool(v));
      prefs_save();
    }
    response = ok_null();
  } else if (g_strcmp0(method, "getString") == 0 || g_strcmp0(method, "getDataString") == 0) {
    const gchar* key = str_arg(args, "key");
    gchar* val = (key && g_key_file_has_key(g_prefs, kGroup, key, nullptr))
        ? g_key_file_get_string(g_prefs, kGroup, key, nullptr) : nullptr;
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        val ? fl_value_new_string(val) : fl_value_new_null()));
    g_free(val);
  } else if (g_strcmp0(method, "setString") == 0 || g_strcmp0(method, "setDataString") == 0) {
    const gchar* key = str_arg(args, "key");
    const gchar* val = str_arg(args, g_strcmp0(method, "setDataString") == 0 ? "json" : "value");
    if (key && val) { g_key_file_set_string(g_prefs, kGroup, key, val); prefs_save(); }
    response = ok_null();
  } else if (g_strcmp0(method, "screenAccess") == 0 || g_strcmp0(method, "requestScreenAccess") == 0) {
    // Phase 1: capture isn't wired yet, but don't block the UI on a permission check.
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(TRUE)));
  } else if (g_strcmp0(method, "beep") == 0) {
    GdkDisplay* d = gdk_display_get_default();
    if (d) gdk_display_beep(d);
    response = ok_null();
  } else if (g_strcmp0(method, "openUrl") == 0 || g_strcmp0(method, "openPath") == 0 ||
             g_strcmp0(method, "reveal") == 0) {
    const gchar* p = str_arg(args, g_strcmp0(method, "openUrl") == 0 ? "url" : "path");
    if (p) {
      gchar* uri = g_strcmp0(method, "openUrl") == 0 ? g_strdup(p)
          : g_filename_to_uri(p, nullptr, nullptr);
      if (uri) { g_app_info_launch_default_for_uri(uri, nullptr, nullptr); g_free(uri); }
    }
    response = ok_null();
  } else if (g_strcmp0(method, "toast") == 0) {
    g_message("SnapNow: %s", str_arg(args, "message") ? str_arg(args, "message") : "");
    response = ok_null();
  } else {
    // Not yet ported to Linux (capture, recording, OCR, clipboard, share, tray/menu…): null = no-op in Dart.
    response = ok_null();
  }

  fl_method_call_respond(call, response, nullptr);
}

void snapnow_native_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr, nullptr);
  // Intentionally leaked for the life of the app, like Flutter's own plugin channels.
}
