#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <cmath>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);

  // Launch at 80% x 90% of the primary monitor work area (taskbar excluded),
  // centered on screen.
  //
  // NOTE: Win32Window::Create scales the provided origin/size by monitor DPI,
  // so values passed here must be in logical (96-DPI) units.
  POINT launch_point{0, 0};
  HMONITOR monitor = MonitorFromPoint(launch_point, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (GetMonitorInfo(monitor, &monitor_info)) {
    const RECT& work = monitor_info.rcWork;
    const int work_width_px = work.right - work.left;
    const int work_height_px = work.bottom - work.top;

    const int target_width_px = static_cast<int>(work_width_px * 0.80);
    const int target_height_px = static_cast<int>(work_height_px * 0.90);
    const int target_x_px = work.left + (work_width_px - target_width_px) / 2;
    const int target_y_px = work.top + (work_height_px - target_height_px) / 2;

    const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
    const double scale_factor = dpi / 96.0;

    auto to_logical_coord = [scale_factor](int physical_px) {
      const int logical_px =
          static_cast<int>(std::lround(physical_px / scale_factor));
      return static_cast<unsigned int>(logical_px < 0 ? 0 : logical_px);
    };

    auto to_logical_size = [scale_factor](int physical_px) {
      const int logical_px =
          static_cast<int>(std::lround(physical_px / scale_factor));
      return static_cast<unsigned int>(logical_px > 0 ? logical_px : 1);
    };

    const unsigned int origin_x = to_logical_coord(target_x_px);
    const unsigned int origin_y = to_logical_coord(target_y_px);
    const unsigned int width = to_logical_size(target_width_px);
    const unsigned int height = to_logical_size(target_height_px);

    origin = Win32Window::Point(origin_x, origin_y);
    size = Win32Window::Size(width, height);
  }

  if (!window.Create(L"clankpad", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
