#include "wire.h"

#include <sstream>

namespace vless_dart {

namespace {

constexpr char kHexDigits[] = "0123456789ABCDEF";

// RFC 3986's unreserved set. Everything else is escaped, including '=' and
// ' ', which would otherwise end a value.
bool Unreserved(unsigned char c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
         (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
         c == '~';
}

bool HexValue(char c, unsigned char* value) {
  if (c >= '0' && c <= '9') {
    *value = static_cast<unsigned char>(c - '0');
  } else if (c >= 'A' && c <= 'F') {
    *value = static_cast<unsigned char>(c - 'A' + 10);
  } else if (c >= 'a' && c <= 'f') {
    *value = static_cast<unsigned char>(c - 'a' + 10);
  } else {
    return false;
  }
  return true;
}

std::string Escape(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (char raw : value) {
    const auto c = static_cast<unsigned char>(raw);
    if (Unreserved(c)) {
      out.push_back(raw);
      continue;
    }
    out.push_back('%');
    out.push_back(kHexDigits[c >> 4]);
    out.push_back(kHexDigits[c & 0x0f]);
  }
  return out;
}

bool Unescape(const std::string& value, std::string* out) {
  std::string result;
  result.reserve(value.size());
  for (size_t i = 0; i < value.size(); ++i) {
    if (value[i] != '%') {
      result.push_back(value[i]);
      continue;
    }
    if (i + 2 >= value.size()) {
      return false;
    }
    unsigned char hi = 0;
    unsigned char lo = 0;
    if (!HexValue(value[i + 1], &hi) || !HexValue(value[i + 2], &lo)) {
      return false;
    }
    result.push_back(static_cast<char>((hi << 4) | lo));
    i += 2;
  }
  *out = std::move(result);
  return true;
}

}  // namespace

std::string Encode(const Fields& fields) {
  // std::map iterates in key order, which matches the Go side's sorted output
  // and keeps logs from both ends diffable.
  std::string out;
  for (const auto& [key, value] : fields) {
    if (!out.empty()) {
      out.push_back(' ');
    }
    out.append(key);
    out.push_back('=');
    out.append(Escape(value));
  }
  return out;
}

bool Decode(const std::string& line, Fields* out) {
  Fields parsed;
  std::istringstream stream(line);
  std::string pair;
  while (stream >> pair) {
    const size_t split = pair.find('=');
    if (split == std::string::npos || split == 0) {
      return false;
    }
    std::string value;
    if (!Unescape(pair.substr(split + 1), &value)) {
      return false;
    }
    parsed[pair.substr(0, split)] = std::move(value);
  }
  *out = std::move(parsed);
  return true;
}

}  // namespace vless_dart
