#include "include/vless_dart/vless_dart_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "vless_dart_plugin.h"

void VlessDartPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  vless_dart::VlessDartPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
