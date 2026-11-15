#include <windows.h>
#include <string>
#include <vector>
#include "utils.h"
#include "app_windows.h"

// No AppWindows is constructed: render-only calls always pass nullptr.
std::wstring AppWindows::NewWindowLabel() const { std::abort(); }
HWND AppWindows::HandleOf(int64_t) const { std::abort(); }
std::vector<HWND> AppWindows::ShownWindows() const { std::abort(); }
HWND AppWindows::FrontWindow() const { std::abort(); }
void AppWindows::Focus(int64_t) { std::abort(); }
void AppWindows::RequestNewWindow() { std::abort(); }
void AppWindows::RequestQuit() { std::abort(); }
void AppWindows::RequestReopen() { std::abort(); }

// attention.cpp's other, uncalled paths link these real utility functions.
std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      result.data(), length);
  return result;
}

std::string Utf8FromUtf16(const wchar_t* text) {
  const std::wstring utf16(text);
  if (utf16.empty()) return std::string();
  int length = WideCharToMultiByte(CP_UTF8, 0, utf16.data(),
                                   static_cast<int>(utf16.size()), nullptr, 0,
                                   nullptr, nullptr);
  std::string result(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, utf16.data(), static_cast<int>(utf16.size()),
                      result.data(), length, nullptr, nullptr);
  return result;
}
