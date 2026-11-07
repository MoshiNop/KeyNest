#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {
std::wstring WideFromUtf8(const std::string& utf8_text) {
  if (utf8_text.empty()) {
    return std::wstring();
  }
  int wide_len = MultiByteToWideChar(
      CP_UTF8, 0, utf8_text.data(), static_cast<int>(utf8_text.size()),
      nullptr, 0);
  if (wide_len <= 0) {
    return std::wstring();
  }
  std::wstring wide_text(wide_len, L'\0');
  MultiByteToWideChar(
      CP_UTF8, 0, utf8_text.data(), static_cast<int>(utf8_text.size()),
      wide_text.data(), wide_len);
  return wide_text;
}

bool SetWindowsSensitiveClipboard(HWND owner, const std::string& utf8_text) {
  std::wstring wide_text = WideFromUtf8(utf8_text);
  if (!OpenClipboard(owner)) {
    return false;
  }
  EmptyClipboard();

  const size_t byte_len = (wide_text.size() + 1) * sizeof(wchar_t);
  HGLOBAL text_mem = GlobalAlloc(GMEM_MOVEABLE, byte_len);
  if (!text_mem) {
    CloseClipboard();
    return false;
  }
  void* locked_text = GlobalLock(text_mem);
  if (!locked_text) {
    GlobalFree(text_mem);
    CloseClipboard();
    return false;
  }
  memcpy(locked_text, wide_text.c_str(), byte_len);
  GlobalUnlock(text_mem);
  if (!SetClipboardData(CF_UNICODETEXT, text_mem)) {
    GlobalFree(text_mem);
    CloseClipboard();
    return false;
  }

  auto set_dword_format = [](const wchar_t* format_name, DWORD value) {
    UINT fmt = RegisterClipboardFormatW(format_name);
    if (fmt == 0) return;
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
    if (!mem) return;
    void* ptr = GlobalLock(mem);
    if (!ptr) {
      GlobalFree(mem);
      return;
    }
    *static_cast<DWORD*>(ptr) = value;
    GlobalUnlock(mem);
    if (!SetClipboardData(fmt, mem)) {
      GlobalFree(mem);
    }
  };

  // Exclude sensitive credentials from Windows Clipboard History and Cloud Clipboard sync.
  set_dword_format(L"ExcludeClipboardContentFromMonitorProcessing", 1);
  set_dword_format(L"CanIncludeInClipboardHistory", 0);
  set_dword_format(L"CanUploadToCloudClipboard", 0);

  CloseClipboard();
  SecureZeroMemory(wide_text.data(), wide_text.size() * sizeof(wchar_t));
  return true;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  misc_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.keynest/misc",
          &flutter::StandardMethodCodec::GetInstance());
  misc_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setSensitiveClipboard") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          auto it = args->find(flutter::EncodableValue("text"));
          if (it == args->end()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const auto* text = std::get_if<std::string>(&it->second);
          if (!text) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          bool ok = SetWindowsSensitiveClipboard(GetHandle(), *text);
          result->Success(flutter::EncodableValue(ok));
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

void FlutterWindow::OnDestroy() {
  misc_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
