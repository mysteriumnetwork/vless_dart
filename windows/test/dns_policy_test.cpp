#include "dns_policy.h"

#include <gtest/gtest.h>
#include <windows.h>

#include <string>

namespace vless_dart {
namespace {

// Never the core's own name: this runs on machines that may have a tunnel up.
constexpr wchar_t kTestRule[] = L"VlessDartPluginTestRule";

constexpr wchar_t kLocalTable[] =
    L"SYSTEM\\CurrentControlSet\\Services\\Dnscache\\Parameters\\"
    L"DnsPolicyConfig";

bool RuleExists(const std::wstring& path) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, path.c_str(), 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  RegCloseKey(key);
  return true;
}

TEST(DnsPolicy, RemovesALeftoverRuleAndSaysWhetherThereWasOne) {
  const std::wstring path = std::wstring(kLocalTable) + L"\\" + kTestRule;

  // An empty key, which is not a rule the DNS client acts on. Not volatile:
  // that would make a table created here volatile too, and the core's own
  // rule could then not be created under it until the next reboot.
  HKEY key = nullptr;
  const LSTATUS created =
      RegCreateKeyExW(HKEY_LOCAL_MACHINE, path.c_str(), 0, nullptr, 0,
                      KEY_WRITE, nullptr, &key, nullptr);
  if (created != ERROR_SUCCESS) {
    GTEST_SKIP() << "writing HKLM needs an elevated session (error "
                 << created << ")";
  }
  RegCloseKey(key);
  ASSERT_TRUE(RuleExists(path));

  EXPECT_TRUE(RemoveDnsRule(kTestRule));
  EXPECT_FALSE(RuleExists(path));

  // Nothing left, which is the answer on every start that follows a clean
  // stop: it must not report a removal, or flush the cache for one.
  EXPECT_FALSE(RemoveDnsRule(kTestRule));
}

}  // namespace
}  // namespace vless_dart
