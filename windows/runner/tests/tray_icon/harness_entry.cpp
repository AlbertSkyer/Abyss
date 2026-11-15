// Include the complete header dependency surface before the test-only access
// macro, so no standard-library or Windows header sees a rewritten "private".
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#define private public
#include "attention.h"
#undef private

#ifdef TRAY_TEST_BASELINE
#include "attention_head.cpp"
#else
#include "attention.cpp"
#endif

namespace {

class NullMessenger final : public flutter::BinaryMessenger {
 public:
  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply = nullptr) const override {}
  void SetMessageHandler(const std::string&,
                         flutter::BinaryMessageHandler) override {}
};

}  // namespace

// These functions deliberately construct real, fully initialized objects.
// TrayIcon and BadgeIcon do not use a window, Flutter engine, or AppWindows.
HICON RenderTray(bool dot) {
  NullMessenger messenger;
  Attention attention(&messenger, nullptr, nullptr);
  return attention.TrayIcon(dot);
}

HICON RenderTaskbarBadge(int count) {
  NullMessenger messenger;
  Attention attention(&messenger, nullptr, nullptr);
  return BadgeIcon(count);
}
