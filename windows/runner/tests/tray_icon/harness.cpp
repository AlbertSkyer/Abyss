#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <gdiplus.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "resource.h"
#include "generated_edition_identity.h"
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "winmm.lib")

HICON RenderTray(bool dot);
HICON RenderTaskbarBadge(int count);

struct Image {
  int width = 0;
  int height = 0;
  std::vector<uint32_t> pixels;  // top-down 0xAARRGGBB, as stored by Canvas
};

struct Resources {
  int gdi = 0;
  int user = 0;
};

Resources CurrentResources() {
  return {static_cast<int>(GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS)),
          static_cast<int>(GetGuiResources(GetCurrentProcess(), GR_USEROBJECTS))};
}

bool ReadIcon(HICON icon, Image* image) {
  if (icon == nullptr) return false;
  ICONINFO info = {};
  if (!GetIconInfo(icon, &info)) return false;
  BITMAP bitmap = {};
  bool result = false;
  if (info.hbmColor != nullptr &&
      GetObjectW(info.hbmColor, sizeof(bitmap), &bitmap) == sizeof(bitmap)) {
    image->width = bitmap.bmWidth;
    image->height = bitmap.bmHeight;
    image->pixels.resize(static_cast<size_t>(image->width) * image->height);
    BITMAPINFO format = {};
    format.bmiHeader.biSize = sizeof(format.bmiHeader);
    format.bmiHeader.biWidth = image->width;
    format.bmiHeader.biHeight = -image->height;
    format.bmiHeader.biPlanes = 1;
    format.bmiHeader.biBitCount = 32;
    format.bmiHeader.biCompression = BI_RGB;
    HDC dc = GetDC(nullptr);
    result = dc != nullptr &&
             GetDIBits(dc, info.hbmColor, 0, image->height, image->pixels.data(),
                       &format, DIB_RGB_COLORS) == image->height;
    if (dc != nullptr) ReleaseDC(nullptr, dc);
  }
  if (info.hbmColor) DeleteObject(info.hbmColor);
  if (info.hbmMask) DeleteObject(info.hbmMask);
  return result;
}

int Encoder(const wchar_t* type, CLSID* id) {
  UINT count = 0, bytes = 0;
  Gdiplus::GetImageEncodersSize(&count, &bytes);
  std::vector<BYTE> data(bytes);
  auto* encoders = reinterpret_cast<Gdiplus::ImageCodecInfo*>(data.data());
  Gdiplus::GetImageEncoders(count, bytes, encoders);
  for (UINT i = 0; i < count; ++i) {
    if (std::wstring(encoders[i].MimeType) == type) {
      *id = encoders[i].Clsid;
      return 0;
    }
  }
  return 1;
}

int SavePng(const Image& source, const wchar_t* path) {
  const int scale = 12;
  Gdiplus::Bitmap bitmap(source.width * scale, source.height * scale,
                         PixelFormat32bppARGB);
  Gdiplus::Graphics graphics(&bitmap);
  graphics.Clear(Gdiplus::Color(255, 45, 48, 54));
  for (int y = 0; y < source.height; ++y) {
    for (int x = 0; x < source.width; ++x) {
      uint32_t pixel = source.pixels[static_cast<size_t>(y) * source.width + x];
      unsigned a = pixel >> 24;
      unsigned r = (pixel >> 16) & 255;
      unsigned g = (pixel >> 8) & 255;
      unsigned b = pixel & 255;
      if (a && a < 255) {
        r = std::min(255u, r * 255 / a);
        g = std::min(255u, g * 255 / a);
        b = std::min(255u, b * 255 / a);
      }
      Gdiplus::SolidBrush brush(Gdiplus::Color(
          static_cast<BYTE>(a), static_cast<BYTE>(r),
          static_cast<BYTE>(g), static_cast<BYTE>(b)));
      graphics.FillRectangle(&brush, x * scale, y * scale, scale, scale);
    }
  }
  CLSID png;
  if (Encoder(L"image/png", &png) != 0) return 1;
  return bitmap.Save(path, &png, nullptr) == Gdiplus::Ok ? 0 : 1;
}

bool Report(bool condition, const char* message, bool* passed) {
  if (condition) return true;
  std::fprintf(stderr, "FAIL: %s\n", message);
  *passed = false;
  return false;
}

uint32_t At(const Image& image, int x, int y) {
  return image.pixels[static_cast<size_t>(y) * image.width + x];
}

int Difference(const Image& current, const Image& baseline,
               const char* label) {
  if (current.width != baseline.width || current.height != baseline.height) {
    std::fprintf(stderr, "DIFF: %s dimensions current=%dx%d baseline=%dx%d\n",
                 label, current.width, current.height, baseline.width,
                 baseline.height);
    return -1;
  }
  int count = 0;
  for (int y = 0; y < current.height; ++y) {
    for (int x = 0; x < current.width; ++x) {
      if (At(current, x, y) == At(baseline, x, y)) continue;
      if (count < 8) {
        std::fprintf(stderr,
                     "DIFF: %s (%d,%d) current=%08lX baseline=%08lX\n", label,
                     x, y, static_cast<unsigned long>(At(current, x, y)),
                     static_cast<unsigned long>(At(baseline, x, y)));
      }
      ++count;
    }
  }
  std::printf("PIXELS: %s differences=%d total=%zu\n", label, count,
              current.pixels.size());
  return count;
}

HICON Take(HICON icon, Image* image, const char* label, bool* passed) {
  if (!Report(icon != nullptr, label, passed)) return nullptr;
  if (!Report(ReadIcon(icon, image), "read returned icon", passed)) {
    DestroyIcon(icon);
    return nullptr;
  }
  return icon;
}

void Export(const Image& image, const std::wstring& directory,
            const wchar_t* name, bool* passed) {
  const std::wstring path = directory + L"\\" + name;
  if (Report(SavePng(image, path.c_str()) == 0, "write PNG", passed)) {
    std::printf("PNG: %ls\n", path.c_str());
  }
  const std::wstring raw_path = directory + L"\\" + name + L".argb";
  FILE* raw = nullptr;
  if (!Report(_wfopen_s(&raw, raw_path.c_str(), L"wb") == 0 && raw != nullptr,
              "create raw baseline pixels", passed)) return;
  const int32_t dimensions[] = {image.width, image.height};
  const bool written = std::fwrite(dimensions, sizeof(dimensions), 1, raw) == 1 &&
                       std::fwrite(image.pixels.data(), sizeof(uint32_t),
                                   image.pixels.size(), raw) == image.pixels.size();
  Report(std::fclose(raw) == 0 && written, "write raw baseline pixels", passed);
}

bool ReadRaw(const std::wstring& path, Image* image) {
  FILE* raw = nullptr;
  if (_wfopen_s(&raw, path.c_str(), L"rb") != 0 || raw == nullptr) return false;
  int32_t dimensions[2] = {};
  const bool read = std::fread(dimensions, sizeof(dimensions), 1, raw) == 1 &&
                    dimensions[0] > 0 && dimensions[1] > 0;
  if (read) {
    image->width = dimensions[0];
    image->height = dimensions[1];
    image->pixels.resize(static_cast<size_t>(image->width) * image->height);
  }
  const bool pixels = read &&
                      std::fread(image->pixels.data(), sizeof(uint32_t),
                                 image->pixels.size(), raw) == image->pixels.size() &&
                      std::fgetc(raw) == EOF;
  return std::fclose(raw) == 0 && pixels;
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 2 || argc > 3) {
    std::fprintf(stderr, "usage: tray_harness.exe OUTPUT_DIRECTORY [BASELINE.exe|baseline]\n");
    return 2;
  }
  const bool baseline_mode = argc == 3 && std::wstring(argv[2]) == L"baseline";
  bool passed = true;
  Gdiplus::GdiplusStartupInput startup;
  ULONG_PTR token = 0;
  if (!Report(Gdiplus::GdiplusStartup(&token, &startup, nullptr) == Gdiplus::Ok,
              "GDI+ startup", &passed)) {
    return 1;
  }
  const std::wstring output = argv[1];
  const std::wstring baseline_output = output + L"\\baseline";
  if (!CreateDirectoryW(output.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    std::fprintf(stderr, "FAIL: create output directory\n");
    return 1;
  }
  if (!CreateDirectoryW(baseline_output.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    std::fprintf(stderr, "FAIL: create baseline directory\n");
    return 1;
  }

  HICON resource = static_cast<HICON>(LoadImageW(
      GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CXSMICON), 0));
  Image resource_image;
  resource = Take(resource, &resource_image, "load bundled resource", &passed);

  Image plain_image;
  HICON plain = Take(RenderTray(false), &plain_image, "plain TrayIcon", &passed);
  Report(plain != resource, "plain must have independent ownership", &passed);
  if (edition::kIsAbyss && plain != nullptr && resource != nullptr) {
    Report(plain_image.pixels == resource_image.pixels,
           "Abyss plain pixels differ from bundled IDI_APP_ICON", &passed);
  }

  Image badge_image;
  HICON badged = Take(RenderTray(true), &badge_image, "badged TrayIcon", &passed);
  Report(badged != plain && badged != resource, "badged ownership", &passed);
  Report(badge_image.width == plain_image.width &&
             badge_image.height == plain_image.height,
         "badged icon size", &passed);

  Image taskbar_one_image, taskbar_nine_image, taskbar_ten_image;
  HICON taskbar_one = Take(RenderTaskbarBadge(1), &taskbar_one_image,
                           "taskbar badge 1", &passed);
  HICON taskbar_nine = Take(RenderTaskbarBadge(9), &taskbar_nine_image,
                            "taskbar badge 9", &passed);
  HICON taskbar_ten = Take(RenderTaskbarBadge(10), &taskbar_ten_image,
                           "taskbar badge 10", &passed);

  const int size = badge_image.width;
  if (badge_image.height == size && size > 0) {
    const double radius = size * 0.17;
    const double cx = size - radius;
    const double cy = radius;
    const double hole = radius + std::max(1.0, size / 16.0);
    Report((At(badge_image, static_cast<int>(cx), static_cast<int>(cy)) &
            0x00FFFFFF) == 0xE81123,
           "badge center is not the expected red", &passed);
    int outside_differences = 0;
    int cleared = 0;
    for (int y = 0; y < size; ++y) {
      for (int x = 0; x < size; ++x) {
        const double dx = x + 0.5 - cx;
        const double dy = y + 0.5 - cy;
        if (dx * dx + dy * dy > (hole + 0.71) * (hole + 0.71) &&
            At(badge_image, x, y) != At(plain_image, x, y)) {
          ++outside_differences;
        }
        if (dx * dx + dy * dy > radius * radius &&
            dx * dx + dy * dy < hole * hole &&
            (At(badge_image, x, y) >> 24) <
                (At(plain_image, x, y) >> 24)) {
          ++cleared;
        }
      }
    }
    Report(outside_differences == 0, "badge changed pixels outside its corner",
           &passed);
    Report(cleared > 0, "badge did not clear artwork in its surrounding corner",
           &passed);
  } else {
    Report(false, "badged icon must be square", &passed);
  }

  const std::pair<const Image*, const wchar_t*> images[] = {
      {&resource_image, L"resource.png"},
      {&plain_image, L"plain.png"},
      {&badge_image, L"badged.png"},
      {&taskbar_one_image, L"taskbar-badge-1.png"},
      {&taskbar_nine_image, L"taskbar-badge-9.png"},
      {&taskbar_ten_image, L"taskbar-badge-10.png"},
  };
  for (const auto& image : images) Export(*image.first, output, image.second, &passed);

  if (!baseline_mode && !edition::kIsAbyss) {
    if (argc != 3) {
      std::fprintf(stderr, "FAIL: current mode needs BASELINE.exe\n");
      return 2;
    }
    const std::wstring command = L"\"\"" + std::wstring(argv[2]) + L"\" \"" +
                                 baseline_output + L"\" baseline\"";
    std::printf("BASELINE COMMAND: %ls\n", command.c_str());
    std::fflush(stdout);
    const int baseline_exit = _wsystem(command.c_str());
    std::printf("BASELINE EXIT: %d\n", baseline_exit);
    if (!Report(baseline_exit == 0, "baseline harness failed", &passed)) {
      // A failing baseline still exports its images and allows a pixel diff.
    }
    const wchar_t* names[] = {
        L"plain.png", L"badged.png", L"taskbar-badge-1.png",
        L"taskbar-badge-9.png", L"taskbar-badge-10.png"};
    const Image* currents[] = {&plain_image, &badge_image, &taskbar_one_image,
                               &taskbar_nine_image, &taskbar_ten_image};
    for (size_t i = 0; i < std::size(names); ++i) {
      const std::wstring path = baseline_output + L"\\" + names[i] + L".argb";
      Image baseline_image;
      if (!Report(ReadRaw(path, &baseline_image), "read baseline raw pixels", &passed)) {
        continue;
      }
      char label[64];
      std::snprintf(label, sizeof(label), "%ls", names[i]);
      Report(Difference(*currents[i], baseline_image, label) == 0,
             "current BaoCode artwork differs from HEAD baseline", &passed);
    }
  }

  const HICON handles[] = {plain, badged, resource, taskbar_one, taskbar_nine,
                           taskbar_ten};
  for (HICON icon : handles) {
    if (icon != nullptr) Report(DestroyIcon(icon), "destroy initial icon", &passed);
  }

  HICON warm_plain = RenderTray(false);
  HICON warm_badged = RenderTray(true);
  Report(warm_plain != nullptr && warm_badged != nullptr, "warm-up render", &passed);
  if (warm_plain != nullptr) DestroyIcon(warm_plain);
  if (warm_badged != nullptr) DestroyIcon(warm_badged);
  const Resources before = CurrentResources();
  int maximum_gdi = before.gdi;
  int maximum_user = before.user;
  for (int i = 0; i < 100; ++i) {
    HICON first = RenderTray(false);
    HICON second = RenderTray(true);
    HICON badge = RenderTaskbarBadge((i % 10) + 1);
    if (!Report(first != nullptr && second != nullptr && badge != nullptr,
                "repeated render returned null", &passed)) break;
    if (!Report(first != second, "live icons must not share a handle", &passed)) break;
    if (!Report(DestroyIcon(first), "repeated plain DestroyIcon", &passed) ||
        !Report(DestroyIcon(second), "repeated badged DestroyIcon", &passed) ||
        !Report(DestroyIcon(badge), "repeated taskbar DestroyIcon", &passed)) break;
    const Resources now = CurrentResources();
    maximum_gdi = std::max(maximum_gdi, now.gdi);
    maximum_user = std::max(maximum_user, now.user);
    if (!Report(now.gdi == before.gdi && now.user == before.user,
                "GDI/USER handles grew during a repeated iteration", &passed)) {
      std::fprintf(stderr, "HANDLES: iteration=%d GDI %d -> %d USER %d -> %d\n",
                   i + 1, before.gdi, now.gdi, before.user, now.user);
      break;
    }
  }
  const Resources after = CurrentResources();
  Report(after.gdi == before.gdi && after.user == before.user,
         "GDI/USER handles grew across 100 renders", &passed);
  std::printf("HANDLES: GDI %d -> %d (max %d); USER %d -> %d (max %d); 100 iterations\n",
              before.gdi, after.gdi, maximum_gdi, before.user, after.user,
              maximum_user);
  std::printf("%s: edition=%ls real Attention; plain/badge/resource, 100 repeated trios\n",
              passed ? "PASS" : "FAIL", edition::kName);
  Gdiplus::GdiplusShutdown(token);
  return passed ? 0 : 1;
}
