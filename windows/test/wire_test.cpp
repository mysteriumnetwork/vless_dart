#include "wire.h"

#include <gtest/gtest.h>

namespace vless_dart {
namespace {

// The Go side sorts keys before encoding, and std::map iterates in key order,
// so both ends produce the same line for the same fields.
TEST(Wire, EncodeSortsKeys) {
  EXPECT_EQ(Encode({{"zulu", "1"}, {"alpha", "2"}, {"mike", "3"}}),
            "alpha=2 mike=3 zulu=1");
}

TEST(Wire, EncodeEscapesSeparators) {
  // A raw space or '=' in a value would end it early and shift every later
  // field by one.
  EXPECT_EQ(Encode({{"k", "a b"}}), "k=a%20b");
  EXPECT_EQ(Encode({{"k", "a=b"}}), "k=a%3Db");
}

// Duplicated in the core's own test, at internal/wire/xcheck_test.go. The two
// implementations have to agree byte for byte or the plugin and the core
// cannot talk, and nothing else in either build would notice if they drifted.
const Fields kGoldenFields = {
    {"empty", ""},
    {"spaces", "a b  c"},
    {"equals", "k=v=w"},
    {"quotes", "he said \"hi\""},
    {"newline", "line1\nline2"},
    {"percent", "100%"},
    {"json", "{\"inbounds\":[{\"port\":0,\"tag\":\"socks-in\"}]}"},
    {"unicode", "\xD1\x82\xD1\x83\xD0\xBD\xD0\xB5\xD0\xBB\xD1\x8C "
                "\xF0\x9F\x87\xB2\xF0\x9F\x87\xB0"},
    {"backslash", "C:\\Program Files\\app.exe"},
};

const char kGoldenLine[] =
    "backslash=C%3A%5CProgram%20Files%5Capp.exe empty= "
    "equals=k%3Dv%3Dw "
    "json=%7B%22inbounds%22%3A%5B%7B%22port%22%3A0%2C%22tag%22%3A%22socks-in%22"
    "%7D%5D%7D "
    "newline=line1%0Aline2 percent=100%25 quotes=he%20said%20%22hi%22 "
    "spaces=a%20b%20%20c "
    "unicode=%D1%82%D1%83%D0%BD%D0%B5%D0%BB%D1%8C%20%F0%9F%87%B2%F0%9F%87%B0";

TEST(Wire, GoldenVectorMatchesTheCore) {
  EXPECT_EQ(Encode(kGoldenFields), kGoldenLine);

  Fields decoded;
  ASSERT_TRUE(Decode(kGoldenLine, &decoded));
  EXPECT_EQ(decoded, kGoldenFields);
}

TEST(Wire, RoundTripsAwkwardValues) {
  const std::string line = Encode(kGoldenFields);
  EXPECT_EQ(line.find('\n'), std::string::npos);

  Fields decoded;
  ASSERT_TRUE(Decode(line, &decoded));
  EXPECT_EQ(decoded, kGoldenFields);
}

TEST(Wire, DecodeRejectsMalformedInput) {
  Fields decoded;
  EXPECT_FALSE(Decode("justakey", &decoded));
  EXPECT_FALSE(Decode("=value", &decoded));
  EXPECT_FALSE(Decode("key=%4", &decoded));
  EXPECT_FALSE(Decode("key=%", &decoded));
  EXPECT_FALSE(Decode("key=%zz", &decoded));
}

TEST(Wire, DecodeAcceptsAnEmptyLine) {
  Fields decoded;
  ASSERT_TRUE(Decode("", &decoded));
  EXPECT_TRUE(decoded.empty());
}

TEST(Wire, DecodeToleratesExtraWhitespace) {
  Fields decoded;
  ASSERT_TRUE(Decode("  a=1   b=2  ", &decoded));
  EXPECT_EQ(decoded.at("a"), "1");
  EXPECT_EQ(decoded.at("b"), "2");
}

// The shapes the core actually emits, so a change to either end that breaks
// the other fails here first.
TEST(Wire, DecodesCoreEvents) {
  Fields decoded;

  ASSERT_TRUE(Decode("event=status status=connected", &decoded));
  EXPECT_EQ(decoded.at("event"), "status");
  EXPECT_EQ(decoded.at("status"), "connected");

  ASSERT_TRUE(Decode("downlink=2048 event=stats id=7 uplink=1024", &decoded));
  EXPECT_EQ(decoded.at("uplink"), "1024");
  EXPECT_EQ(decoded.at("downlink"), "2048");
  EXPECT_EQ(decoded.at("id"), "7");

  ASSERT_TRUE(Decode("event=error id=3 message=start%20xray%3A%20boom",
                     &decoded));
  EXPECT_EQ(decoded.at("message"), "start xray: boom");
}

}  // namespace
}  // namespace vless_dart
