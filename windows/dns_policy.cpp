#include "dns_policy.h"

#include <windows.h>

#include <string>

namespace vless_dart {

namespace {

// Both tables, as the core does when it removes its own rule: it writes to
// the Group Policy one when that exists, and which one exists can change
// between a rule going in and coming out.
constexpr wchar_t kLocalTable[] =
    L"SYSTEM\\CurrentControlSet\\Services\\Dnscache\\Parameters\\"
    L"DnsPolicyConfig";
constexpr wchar_t kPolicyTable[] =
    L"SOFTWARE\\Policies\\Microsoft\\Windows NT\\DNSClient\\"
    L"DnsPolicyConfig";

// Deleting the key is what lifts the policy; this drops the answers that
// were resolved, or failed to resolve, while it was in force.
void FlushResolverCache() {
  // Exported by dnsapi.dll but in no import library, so it is looked up.
  const HMODULE dnsapi =
      LoadLibraryExW(L"dnsapi.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (dnsapi == nullptr) {
    return;
  }
  using Flush = BOOL(WINAPI*)();
  const FARPROC found = GetProcAddress(dnsapi, "DnsFlushResolverCache");
  if (found != nullptr) {
    // Through void(*)(), which is the one function type a cast to another
    // is not flagged for.
    const auto flush =
        reinterpret_cast<Flush>(reinterpret_cast<void (*)()>(found));
    flush();
  }
  FreeLibrary(dnsapi);
}

}  // namespace

const wchar_t kCoreDnsRule[] = L"MysteriumVlessDns";

bool RemoveDnsRule(const wchar_t* rule_name) {
  bool removed = false;
  for (const wchar_t* table : {kLocalTable, kPolicyTable}) {
    const std::wstring key = std::wstring(table) + L"\\" + rule_name;
    // Fails without a rule to delete, and without the rights to: a host that
    // is not elevated could not have had a core install one.
    if (RegDeleteKeyW(HKEY_LOCAL_MACHINE, key.c_str()) == ERROR_SUCCESS) {
      removed = true;
    }
  }
  if (removed) {
    FlushResolverCache();
  }
  return removed;
}

}  // namespace vless_dart
