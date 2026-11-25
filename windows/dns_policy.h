#ifndef FLUTTER_PLUGIN_VLESS_DART_DNS_POLICY_H_
#define FLUTTER_PLUGIN_VLESS_DART_DNS_POLICY_H_

namespace vless_dart {

// The core's rule in the Name Resolution Policy Table. Has to stay the same as
// nrptRuleName in vless-core's nrpt_windows.go, which is what writes it.
extern const wchar_t kCoreDnsRule[];

// Removes the DNS policy rule |rule_name| and reports whether there was one.
//
// While a tunnel is up the core keeps a rule that sends every lookup on the
// machine to a resolver inside the tunnel. It takes the rule out again when
// it is asked to stop -- but a core that crashed or was killed is not asked,
// and the rule is a registry key: it stays, through a reboot, and the machine
// has no working DNS for as long as it does.
//
// The core clears a leftover when it next starts, which is only on the next
// connect. That is too late for an app that has to reach its API, by name,
// before it can connect at all. So the plugin clears it too, whenever it
// knows no core of its own is running.
//
// Only ever deletes, and only that one named rule.
bool RemoveDnsRule(const wchar_t* rule_name);

}  // namespace vless_dart

#endif  // FLUTTER_PLUGIN_VLESS_DART_DNS_POLICY_H_
