#ifndef FLUTTER_PLUGIN_VLESS_DART_WIRE_H_
#define FLUTTER_PLUGIN_VLESS_DART_WIRE_H_

#include <map>
#include <string>

namespace vless_dart {

// One message of the line protocol spoken with vless_core.exe: space-separated
// key=value pairs with percent-encoded values.
//
// The mirror of internal/wire in vless-core. Not JSON because no JSON library
// is available to a Flutter Windows plugin, and hand-rolling a parser to read
// something this small is a worse trade than a format with nothing to get
// wrong.
using Fields = std::map<std::string, std::string>;

// Encode renders fields as a single line, without the trailing newline.
std::string Encode(const Fields& fields);

// Decode parses one line. Returns false on a malformed pair or a bad escape,
// leaving |out| untouched.
bool Decode(const std::string& line, Fields* out);

}  // namespace vless_dart

#endif  // FLUTTER_PLUGIN_VLESS_DART_WIRE_H_
